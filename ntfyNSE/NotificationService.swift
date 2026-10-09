import UserNotifications
import CoreData
import CryptoKit

/// This app extension is responsible for persisting the incoming notification to the data store (Core Data). It will eventually be the entity that
/// fetches notification content from selfhosted servers (when a "poll request" is received). This is not implemented yet.
///
/// Note that the app extension does not run as part of the main app, so log messages are not printed in the main Xcode window. To debug,
/// select Debug -> Attach to Process by PID or Name, and select the extension. Don't forget to set a breakpoint, or you're not gonna have a good time.
class NotificationService: UNNotificationServiceExtension {
    private let tag = "NotificationService"
    private var store: Store?
    
    var bestAttemptContent: UNMutableNotificationContent?
    private var deliveryGate: NotificationDeliveryGate?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // On a Mac this process can outlive the banner and receive its taps; pass them to the app.
        NotificationResponseRelay.installInExtensionIfNeeded()
        self.store = Store.shared
        self.deliveryGate = NotificationDeliveryGate(handler: contentHandler)
        self.bestAttemptContent = (fallbackContent(request).mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent = bestAttemptContent {
            let userInfo = bestAttemptContent.userInfo
            guard let message = Message.from(userInfo: userInfo) else {
                Log.w(tag, "Message cannot be parsed from userInfo", userInfo)
                deliver(fallbackContent(request))
                return
            }
            Log.d(
                tag,
                "\(#function) event=\(message.event), topic=\(message.topic), pollId=\(message.pollId ?? "<nil>"), baseUrl=\(userInfo["base_url"] as? String ?? "<nil>")"
            )
            switch message.event {
            case "poll_request":
                handlePollRequest(request, bestAttemptContent, message)
            case "message", "message_clear", "message_delete":
                let baseUrl = userInfo["base_url"]  as? String ?? Config.appBaseUrl // messages only come for the main server
                handleMessage(request, bestAttemptContent, baseUrl, message)
            default:
                Log.w(tag, "Irrelevant message received", message)
                deliver(fallbackContent(request))
            }
        } else {
            deliver(fallbackContent(request))
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content,
        // otherwise the original push payload will be used.

        Log.w(tag, "\(#function): delivering best attempt content")
        if let bestAttemptContent = bestAttemptContent {
            deliver(bestAttemptContent)
        }
    }

    /// The push exactly as received, unless its text is an end-to-end encrypted body: a server that
    /// sends full messages (not poll requests) puts the JWE in the alert, and every early-exit path
    /// would otherwise show that ciphertext on the lock screen.
    private func fallbackContent(_ request: UNNotificationRequest) -> UNNotificationContent {
        UNNotificationContent.encryptionSafeFallback(request.content)
    }

    private func deliver(_ content: UNNotificationContent) {
        if deliveryGate?.deliver(content) == false {
            Log.w(tag, "Ignoring late notification delivery after the content handler already fired")
        }
    }
    
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ received: Message) {
        // Save notification first so attachment downloads can update persistent state. What comes back
        // is the message as stored: decrypted for an end-to-end encrypted topic (or its "Encrypted
        // message" placeholder), so the banner never shows ciphertext and matches the in-app row.
        guard let result = store?.ingest(pushedMessage: received, baseUrl: baseUrl, topic: received.topic) else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: received.topic)) unknown")
            deliver(fallbackContent(request))
            return
        }
        if case .reconcile(let poll) = result {
            ApiService.shared.poll(poll, timeout: NotificationServiceTiming.pollTimeout) { messages, _ in
                guard let messages else { self.deliver(self.fallbackContent(request)); return }
                let presentations = Store.shared.save(notificationsFromMessages: messages, polledWith: poll) ?? []
                if let latest = presentations.last(where: { $0.sequence == received.sequence }) {
                    self.handlePresentation(request, content, baseUrl, latest, reconciled: true)
                } else {
                    self.deliverSynchronizationReceipt(content, baseUrl, received)
                }
            }
            return
        }
        if case .handled = result {
            deliverSynchronizationReceipt(content, baseUrl, received)
            return
        }
        guard case .stored(let message) = result else {
            // A re-posted copy of an encrypted message this topic already has: it is not stored again.
            // Empty content would NOT hide the banner (that needs the filtering entitlement, which this
            // app doesn't have); iOS would show the server's original alert. Show the neutral
            // "Encrypted message" placeholder instead.
            Log.w(tag, "Replayed encrypted message; not storing it, showing the neutral placeholder")
            deliver(UNNotificationContent.replayedEncryptedMessage(request.content))
            return
        }
        handlePresentation(request, content, baseUrl, message)
    }

    private func deliverSynchronizationReceipt(_ content: UNMutableNotificationContent, _ baseUrl: String, _ received: Message) {
        // A custom relay may wrap a control in an alert. Suppressing that alert entirely needs
        // the filtering entitlement; use a passive receipt instead of the original placeholder.
        content.title = "ntfy"
        content.body = "Notification state synchronized"
        content.subtitle = ""
        content.attachments = []
        content.categoryIdentifier = ""
        content.sound = nil
        content.interruptionLevel = .passive
        content.badge = NSNumber(value: Store.shared.totalUnreadCount())
        content.userInfo = received.toUserInfo()
        content.userInfo["base_url"] = baseUrl
        deliver(content)
    }

    private func handlePresentation(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, reconciled: Bool = false) {
        Store.shared.recordPresentation(message: message, baseUrl: baseUrl)
        let user = store?.getBasicUser(baseUrl: baseUrl)
        let displayName = store?.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        content.modify(
            message: message,
            baseUrl: baseUrl,
            displayName: displayName,
            categoryRegistrationTimeout: NotificationServiceTiming.categoryRegistrationTimeout
        )
        content.attachImageIfNeeded(
            message: message,
            baseUrl: baseUrl,
            user: user,
            timeout: reconciled ? NotificationServiceTiming.reconciliationAttachmentTimeout : NotificationServiceTiming.attachmentTimeout
        ) {
            self.deliver(content)
        }
    }
    
    private func handlePollRequest(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ pollRequest: Message) {
        let pollId = pollRequest.pollId ?? pollRequest.id
        let preferredBaseUrl = bestAttemptContent?.userInfo["base_url"] as? String
        guard let subscription = store?.findSubscriptionMatch(
                forPollRequestTopic: pollRequest.topic,
                preferredBaseUrl: preferredBaseUrl
            )
        else {
            Log.w(tag, "Cannot find subscription for poll request topic=\(pollRequest.topic), pollId=\(pollRequest.pollId ?? "<nil>")")
            deliver(fallbackContent(request))
            return
        }
        
        // Poll original server
        let user = store?.getBasicUser(baseUrl: subscription.baseUrl)
        // The extension only needs contentHandler to be called from the async callback
        ApiService.shared.poll(
            baseUrl: subscription.baseUrl,
            topic: subscription.topic,
            messageId: pollId,
            user: user,
            timeout: NotificationServiceTiming.pollTimeout
        ) { message, error in
            guard let message = message else {
                Log.w(self.tag, "Error fetching poll request message topic=\(pollRequest.topic), pollId=\(pollId), subscription=\(topicUrl(baseUrl: subscription.baseUrl, topic: subscription.topic))", error)
                self.deliver(self.fallbackContent(request))
                return
            }
            self.handleMessage(request, content, subscription.baseUrl, message)
        }
    }
}

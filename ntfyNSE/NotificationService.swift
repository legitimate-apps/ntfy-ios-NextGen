#if NTFY_NSE_TEST_HOST
@testable import ntfy
#endif
import UserNotifications
import CoreData
import CryptoKit

/// Persists incoming messages in Core Data and fetches notification content from the original
/// server when a "poll_request" wakeup is received.
///
/// Note that the app extension does not run as part of the main app, so log messages are not printed in the main Xcode window. To debug,
/// select Debug -> Attach to Process by PID or Name, and select the extension. Don't forget to set a breakpoint, or you're not gonna have a good time.
class NotificationService: UNNotificationServiceExtension {
    private let tag = "NotificationService"
    private var store: Store?
    var makeStore: () -> Store = { Store.shared } // Test host can exercise an NSE-first disk migration.
    
    private let attempt = NotificationBestAttempt(UNMutableNotificationContent())
    var bestAttemptContent: UNMutableNotificationContent? {
        get { attempt.content }
        set { if let newValue { attempt.replace(with: newValue) } }
    }
    private var deliveryGate: NotificationDeliveryGate?
    private let presentationLock = NSLock()
    private var processedMessage: Message?
    private var presentationMessage: Message? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return processedMessage }
        set { presentationLock.lock(); defer { presentationLock.unlock() }; processedMessage = newValue }
    }
    
    private var alertIdentity: (message: Message, baseUrl: String)? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return processedIdentity }
        set {
            // Capture evidence before asynchronous I/O. Expiry uses only this snapshot, never a
            // queue, shared file lock, or database fetch. Uncertainty deliberately allows delivery.
            let alerted = newValue.map { store?.wasAlerted(message: $0.message, baseUrl: $0.baseUrl) ?? false } ?? false
            let muted = newValue.map { store?.isTopicMuted(baseUrl: $0.baseUrl, topic: $0.message.topic) ?? false } ?? false
            presentationLock.lock(); defer { presentationLock.unlock() }
            processedIdentity = newValue
            expiryIsQuiet = alerted || muted
        }
    }
    private var expiryIsQuiet = false
    private var processedIdentity: (message: Message, baseUrl: String)?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // On a Mac this process can outlive the banner and receive its taps; pass them to the app.
        NotificationResponseRelay.installInExtensionIfNeeded()
        NotificationExtensionLifetime.shared.requestStarted()
        if self.store == nil { self.store = makeStore() }
        self.deliveryGate = NotificationDeliveryGate(handler: contentHandler)
        presentationMessage = nil
        alertIdentity = nil
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
            deliver(bestAttemptContent, expiring: true)
        }
    }

    /// The push exactly as received, unless its text is an end-to-end encrypted body: a server that
    /// sends full messages (not poll requests) puts the JWE in the alert, and every early-exit path
    /// would otherwise show that ciphertext on the lock screen.
    private func fallbackContent(_ request: UNNotificationRequest) -> UNNotificationContent {
        UNNotificationContent.encryptionSafeFallback(request.content)
    }

    private func deliver(_ content: UNNotificationContent, expiring: Bool = false) {
        let final = content.mutableCopy() as! UNMutableNotificationContent
        if let presentationMessage { final.configureInterruption(message: presentationMessage) }
        if !expiring { final.applyTopicMute() }
        let handoff = { (output: UNNotificationContent) -> Bool in
            guard self.deliveryGate?.deliver(output) == true else {
                Log.w(self.tag, "Ignoring late notification delivery after the content handler already fired")
                return false
            }
            NotificationExtensionLifetime.shared.requestFinished()
            return true
        }
        if expiring {
            presentationLock.lock()
            let quiet = expiryIsQuiet
            presentationLock.unlock()
            if quiet { final.sound = nil; final.interruptionLevel = .passive; final.relevanceScore = 0 }
            _ = handoff(final)
            return
        }
        guard let identity = alertIdentity, let store else {
            _ = handoff(final)
            return
        }
        // Passive content prevents a duplicate banner/sound. Fully removing the Notification Center
        // entry would require Apple's notification-filtering entitlement; empty content is unsafe.
        let gate = deliveryGate
        store.deliverAlert(message: identity.message, baseUrl: identity.baseUrl, recordBeforeDelivery: true,
                           stillNeeded: { gate?.isPending == true }, delivery: { finished in
            finished(handoff(final))
        }, suppressed: {
            let quiet = final.mutableCopy() as! UNMutableNotificationContent
            quiet.sound = nil
            quiet.interruptionLevel = .passive
            quiet.relevanceScore = 0
            _ = handoff(quiet)
        })
    }
    
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ received: Message) {
        if received.event == "message" { alertIdentity = (received, baseUrl) }
        // Save notification first so attachment downloads can update persistent state. What comes back
        // is the message as stored: decrypted for an end-to-end encrypted topic (or its "Encrypted
        // message" placeholder), so the banner never shows ciphertext and matches the in-app row.
        guard let result = store?.ingest(pushedMessage: received, baseUrl: baseUrl, topic: received.topic) else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: received.topic)) unknown")
            deliver(fallbackContent(request))
            return
        }
        if case .reconcile(let poll) = result {
            let placeholder = NotificationHealth.fetchFailureContent(request.content, topic: received.topic, baseUrl: baseUrl, event: received.event)
            bestAttemptContent = placeholder
            ApiService.shared.poll(poll, timeout: NotificationServiceTiming.pollTimeout) { messages, _ in
                guard let messages else { self.deliver(placeholder); return }
                guard let presentations = Store.shared.save(notificationsFromMessages: messages, polledWith: poll) else {
                    self.deliver(placeholder)
                    return
                }
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
        content.body = String(localized: "Notification state synchronized")
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
        bestAttemptContent = content
        let user = store?.getBasicUser(baseUrl: baseUrl)
        let displayName = store?.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        content.modify(
            message: message,
            baseUrl: baseUrl,
            displayName: displayName,
            categoryRegistrationTimeout: NotificationServiceTiming.categoryRegistrationTimeout
        )
        presentationMessage = message
        bestAttemptContent = content
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
        
        // Even a failed fetch/expiry must not re-alert a known id. Unknown ids fail open.
        alertIdentity = (Message(id: pollId, time: pollRequest.time, event: "message", topic: subscription.topic), subscription.baseUrl)
        // Install the safe topic-named fallback before starting the fetch, including expiry.
        let placeholder = NotificationHealth.fetchFailureContent(request.content, topic: subscription.topic, baseUrl: subscription.baseUrl)
        bestAttemptContent = placeholder
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
                self.deliver(NotificationHealth.fetchFailureContent(placeholder, topic: subscription.topic, failure: PollFailure.classify(error)))
                return
            }
            self.handleMessage(request, content, subscription.baseUrl, message)
        }
    }
}

#if NTFY_NSE_TEST_HOST
@testable import ntfy
#endif
import UserNotifications
import CoreData
import CryptoKit
import os.log

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
    var soundLibrary: TopicSoundLibrary = .shared
    private var processedMessage: (message: Message, soundName: String?)?
    private var presentationMessage: (message: Message, soundName: String?)? {
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
    private var quietHours = QuietHours.load()
    private var expiryIsQuiet = false
    private var processedIdentity: (message: Message, baseUrl: String)?
    /// Settled before the slow steps of a presentation: true when this extension alerts the
    /// message, false when the app or an earlier delivery already did. Nil means not claimed.
    private var alertClaim: Bool? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return claimedAlert }
        set {
            presentationLock.lock(); defer { presentationLock.unlock() }
            claimedAlert = newValue
            if newValue == false { expiryIsQuiet = true }
        }
    }
    private var claimedAlert: Bool?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // On a Mac this process can outlive the banner and receive its taps; pass them to the app.
        NotificationResponseRelay.installInExtensionIfNeeded()
        NotificationExtensionLifetime.shared.requestStarted()
        if self.store == nil { self.store = makeStore() }
        self.deliveryGate = NotificationDeliveryGate { output in
            // Release builds expose only presentation metadata, never message or account content.
            os_log("NSE handoff soundRequested=%{public}d interruptionLevel=%{public}ld",
                   log: OSLog(subsystem: Config.bundleIdBase, category: "NotificationPresentation"), type: .info,
                   output.sound == nil ? 0 : 1, output.interruptionLevel.rawValue)
            contentHandler(output)
        }
        quietHours = QuietHours.load()
        presentationMessage = nil
        alertIdentity = nil
        alertClaim = nil
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

    private func deliver(_ content: UNNotificationContent, expiring: Bool = false, quietReady: Bool = false) {
        if !expiring, !quietReady, let store {
            store.quietAlerts.flush { self.deliver(content, quietReady: true) }
            return
        }
        let final = content.mutableCopy() as! UNMutableNotificationContent
        if let presentationMessage { final.configureInterruption(message: presentationMessage.message, soundName: presentationMessage.soundName) }
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
            store?.quietAlerts.cancelScheduling()
            presentationLock.lock()
            var info = final.userInfo
            if let identity = processedIdentity {
                info["base_url"] = identity.baseUrl; info["topic"] = identity.message.topic
            }
            let quiet = expiryIsQuiet || quietHours.isQuiet(userInfo: info)
            presentationLock.unlock()
            if quiet { final.sound = nil; final.interruptionLevel = .passive; final.relevanceScore = 0 }
            _ = handoff(final)
            return
        }
        // Passive content prevents a duplicate banner/sound. Fully removing the Notification Center
        // entry would require Apple's notification-filtering entitlement; empty content is unsafe.
        let passive = {
            let quiet = final.mutableCopy() as! UNMutableNotificationContent
            quiet.sound = nil
            quiet.interruptionLevel = .passive
            quiet.relevanceScore = 0
            _ = handoff(quiet)
        }
        if let claim = alertClaim {
            if claim { _ = handoff(final) } else { passive() }
            return
        }
        guard let identity = alertIdentity, let store else {
            _ = handoff(final)
            return
        }
        let gate = deliveryGate
        store.deliverAlert(message: identity.message, baseUrl: identity.baseUrl, recordBeforeDelivery: true,
                           stillNeeded: { gate?.isPending == true }, delivery: { finished in
            finished(handoff(final))
        }, suppressed: passive)
    }

    /// Records the alert for a stored message before category registration and the attachment
    /// download, not at the handoff. Once the content handler is pending, iOS shows this push whether
    /// the extension finishes, expires (best attempt) or is killed (original payload), and expiry
    /// itself may not touch the store. A later presenting poll then sees `alerted` and stays quiet.
    private func claimAlert(then next: @escaping () -> Void) {
        guard let identity = alertIdentity, let store else { next(); return }
        let gate = deliveryGate
        let proceed = { (alerting: Bool) in
            self.alertClaim = alerting
            DispatchQueue.global(qos: .userInitiated).async(execute: next)
        }
        // If expiry already handed off, neither closure runs and nothing remains to present.
        store.deliverAlert(message: identity.message, baseUrl: identity.baseUrl, recordBeforeDelivery: true,
                           stillNeeded: { gate?.isPending == true },
                           delivery: { _ in proceed(true) }, suppressed: { proceed(false) })
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
        claimAlert { self.presentClaimed(content, baseUrl, message, reconciled: reconciled) }
    }

    private func presentClaimed(_ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, reconciled: Bool) {
        let user = store?.getBasicUser(baseUrl: baseUrl)
        let displayName = store?.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        let soundName = store?.topicSoundName(baseUrl: baseUrl, topic: message.topic, library: soundLibrary)
        content.modify(
            message: message,
            baseUrl: baseUrl,
            displayName: displayName,
            soundName: soundName,
            categoryRegistrationTimeout: NotificationServiceTiming.categoryRegistrationTimeout
        )
        presentationMessage = (message, soundName)
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
        // The server's mutable alert omits aps.sound. Every fallback needs an explicit policy.
        content.configureInterruption(message: pollRequest)
        let pollId = pollRequest.pollId ?? pollRequest.id
        let preferredBaseUrl = bestAttemptContent?.userInfo["base_url"] as? String
        guard let subscription = store?.findSubscriptionMatch(
                forPollRequestTopic: pollRequest.topic,
                preferredBaseUrl: preferredBaseUrl
            )
        else {
            Log.w(tag, "Cannot find subscription for poll request topic=\(pollRequest.topic), pollId=\(pollRequest.pollId ?? "<nil>")")
            let fallback = fallbackContent(request).mutableCopy() as! UNMutableNotificationContent
            fallback.configureInterruption(message: pollRequest)
            deliver(fallback)
            return
        }
        
        // Even a failed fetch/expiry must not re-alert a known id. Unknown ids fail open.
        alertIdentity = (Message(id: pollId, time: pollRequest.time, event: "message", topic: subscription.topic), subscription.baseUrl)
        // Install the safe topic-named fallback before starting the fetch, including expiry.
        let placeholder = NotificationHealth.fetchFailureContent(request.content, topic: subscription.topic, baseUrl: subscription.baseUrl)
        placeholder.configureInterruption(message: pollRequest,
            soundName: store?.topicSoundName(baseUrl: subscription.baseUrl, topic: subscription.topic, library: soundLibrary))
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

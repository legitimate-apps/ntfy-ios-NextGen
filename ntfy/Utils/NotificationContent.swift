import Foundation
import UserNotifications
import CryptoKit

enum NotificationServiceTiming {
    static let processingBudget: TimeInterval = 25
    static let pollTimeout: TimeInterval = 8
    static let categoryRegistrationTimeout: TimeInterval = 2
    static let attachmentTimeout: TimeInterval = 8
    static let reconciliationAttachmentTimeout: TimeInterval = 6
    /// The NSE is publisher-triggered and cannot expose progress or cancellation. Five MiB needs
    /// roughly 5.25 Mbps to complete inside the eight-second attachment window, while larger files
    /// remain available for an explicit in-app download.
    static let attachmentSizeCeiling: Int64 = 5 * 1024 * 1024

    static var worstCaseDuration: TimeInterval {
        max(pollTimeout + categoryRegistrationTimeout + attachmentTimeout,
            2 * pollTimeout + categoryRegistrationTimeout + reconciliationAttachmentTimeout)
    }
}

final class NotificationDeliveryGate {
    private let handler: (UNNotificationContent) -> Void
    private let lock = NSLock()
    private var hasDelivered = false

    init(handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    @discardableResult
    func deliver(_ content: UNNotificationContent) -> Bool {
        lock.lock()
        guard !hasDelivered else {
            lock.unlock()
            return false
        }
        hasDelivered = true
        lock.unlock()
        handler(content)
        return true
    }
}

func notificationServiceAttachmentDownloadLimit(configuredMaxSize: Int64?) -> Int64 {
    min(
        configuredMaxSize ?? NotificationServiceTiming.attachmentSizeCeiling,
        NotificationServiceTiming.attachmentSizeCeiling
    )
}

extension UNNotificationContent {
    /// What the extension shows when it exits before processing a push (unknown topic, timeout,
    /// decode failure). If the text is an end-to-end encrypted body, show the plain locked
    /// placeholder and nothing else the server supplied: no ciphertext, and no title, subtitle or
    /// attachment that an outsider could pair with a genuine-looking "Encrypted message".
    /// Anything else is shown exactly as received.
    static func encryptionSafeFallback(_ content: UNNotificationContent) -> UNNotificationContent {
        guard TopicEncryption.isEncrypted(content.body) || TopicEncryption.isEncrypted(content.title)
                || TopicEncryption.isEncrypted(content.subtitle) else {
            return content
        }
        return replayedEncryptedMessage(content)
    }

    /// What the extension shows for a replayed encrypted message (already stored, so not stored
    /// again). The app has no notification-filtering entitlement, so handing back empty content would
    /// make iOS show the original alert: whatever title the server sent, with ciphertext as the body.
    /// Instead it shows the neutral placeholder and nothing the server supplied.
    static func replayedEncryptedMessage(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let safe = content.mutableCopy() as? UNMutableNotificationContent else {
            return UNNotificationContent()
        }
        safe.title = ""
        safe.subtitle = ""
        safe.body = TopicEncryption.lockedPlaceholder
        safe.attachments = []
        safe.categoryIdentifier = ""
        return safe
    }
}

extension UNMutableNotificationContent {
    func modify(
        message: Message,
        baseUrl: String,
        displayName: String? = nil,
        categoryRegistrationTimeout: TimeInterval = 3
    ) {
        // Body and title.
        // Always overwrite the body once we've processed the message — even when it
        // has no text (title-only / attachment-only). Otherwise the incoming push
        // placeholder ("New message") leaks through on the success path for any
        // message without a `message` field (ntfy iOS #1080).
        self.body = message.message ?? ""
        
        // Set notification title to the subscription's display name (which is its custom name, if the
        // user renamed it) and fall back to the short URL. The title is always set by the server, but
        // it may be empty — and titleless messages are the common case, so without this a renamed
        // subscription's notifications would keep showing the raw topic URL even though the
        // subscription list and notification header show the custom name.
        if let title = message.title, title != "" {
            self.title = title
        } else {
            let customTitle = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = (customTitle?.isEmpty == false)
                ? customTitle!
                : topicShortUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // A plaintext message on a topic with an end-to-end password may not come from the sender.
        if message.encryption == .unencrypted {
            self.subtitle = TopicEncryption.unencryptedMarker
        }

        // Emojify title or message
        let emojiTags = parseEmojiTags(message.tags)
        if !emojiTags.isEmpty {
            if let title = message.title, title != "" {
                self.title = emojiTags.joined(separator: "") + " " + self.title
            } else {
                self.body = emojiTags.joined(separator: "") + " " + self.body
            }
        }
        
        // Add custom actions
        //
        // We re-define the categories every time here, which is weird, but it works. When tapped, the action sets the
        // actionIdentifier in the application(didReceive) callback. This logic is handled in the AppDelegate. This approach
        // is described in a comment in https://stackoverflow.com/questions/30103867/changing-action-titles-in-interactive-notifications-at-run-time#comment122812568_30107065
        //
        // We also must set the .foreground flag, which brings the notification to the foreground and avoids an error about
        // permissions. This is described in https://stackoverflow.com/a/44580916/1440785
        configureNotificationActions(message: message, timeout: categoryRegistrationTimeout)
        
        // Group by topic, and only elevate priority 5 alerts to critical when the user opted in
        // and iOS has granted critical alert permission.
        self.threadIdentifier = topicUrl(baseUrl: baseUrl, topic: message.topic)
        
        // Map priorities to interruption level (light up screen, ...) and relevance (order)
        switch message.priority {
        case 1:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0
        case 2:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0.25
        case 4:
            self.sound = .default
            self.interruptionLevel = .timeSensitive
            self.relevanceScore = 0.75
        case 5:
            if Store.shared.getCriticalAlertsEnabled() && Store.getCriticalAlertsAuthorized() {
                self.sound = .defaultCritical
                self.interruptionLevel = .critical
            } else {
                self.sound = .default
                self.interruptionLevel = .timeSensitive
            }
            self.relevanceScore = 1
        default:
            self.sound = .default
            self.interruptionLevel = .active
            self.relevanceScore = 0.5
        }
        
        if message.isUpdate {
            self.sound = nil
            self.interruptionLevel = .passive
        }

        // Carry the unread total on the badge (ntfy#1462). Both delivery paths — the notification
        // service extension and the app's own background poll — persist the message before calling
        // us, so this count already includes it. Setting it on the content is the only thing that
        // can move the app icon while the app itself never runs; the app corrects the badge back
        // down from `AppDelegate.startBadgeSync` as soon as the user reads anything.
        self.badge = NSNumber(value: Store.shared.totalUnreadCount())

        // Make sure the userInfo matches, so that when the notification is tapped, the AppDelegate
        // can properly navigate to the right topic and re-assemble the message.
        self.userInfo = message.toUserInfo()
        self.userInfo["base_url"] = baseUrl
    }

    func attachImageIfNeeded(
        message: Message,
        baseUrl: String,
        user: BasicUser?,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        session: URLSession? = nil,
        timeout: TimeInterval = 20,
        completionHandler: @escaping () -> Void
    ) {
        guard let attachment = message.attachment else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }
        guard attachment.isImageAttachment(), let url = URL(string: attachment.url) else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }

        if let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
            notificationID: message.id,
            remoteUrl: url,
            attachment: attachment,
            mimeType: attachment.type
        ) {
            DispatchQueue.main.async {
                let didAttachImage = self.attachLocalImage(from: localFileUrl)
                self.completeAttachmentHandling(message: message, didAttachImage: didAttachImage, completionHandler: completionHandler)
            }
            return
        }

        // Honor Settings -> "Download attachments" before touching the network. Reusing an already
        // downloaded file above is deliberately not gated — it costs no traffic, and the setting is
        // about fetching. When we skip, completeAttachmentHandling still appends the name/size summary,
        // so the attachment is announced rather than silently dropped.
        guard Store.shared.shouldAutoDownloadAttachment(attachment) else {
            Log.d("NotificationContent", "Skipping attachment auto-download per user preference", message.id)
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }

        // Tests may inject a recording session to prove whether policy starts a request at all.
        // Production uses the shared bounded downloader below, which cancels as bytes arrive and
        // verifies the final file size even when neither the payload nor HTTP response declared it.
        if let session {
            let request = AttachmentFileStore.makeRequest(
                remoteUrl: url,
                baseUrl: baseUrl,
                authorizationHeader: user?.toHeader(),
                credentialStore: credentialStore
            )
            session.downloadTask(with: request) { _, _, _ in
                self.completeAttachmentHandling(
                    message: message,
                    didAttachImage: false,
                    completionHandler: completionHandler
                )
            }.resume()
            return
        }

        let configuredMaxSize = Store.shared.resolvedAttachmentAutoDownloadMaxSize()
        let maxSize = notificationServiceAttachmentDownloadLimit(configuredMaxSize: configuredMaxSize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        Task {
            do {
                let downloaded = try await AttachmentFileStore.download(
                    notificationID: message.id,
                    remoteUrl: url,
                    attachment: attachment,
                    baseUrl: baseUrl,
                    authorizationHeader: user?.toHeader(),
                    credentialStore: credentialStore,
                    maxSize: maxSize,
                    configuration: configuration
                )
                Store.shared.completeAttachmentDownload(
                    notificationID: message.id,
                    localPath: downloaded.localFileUrl.path,
                    resolvedType: downloaded.mimeType,
                    resolvedSize: downloaded.size
                )
                DispatchQueue.main.async {
                    let didAttachImage = self.attachLocalImage(from: downloaded.localFileUrl)
                    self.completeAttachmentHandling(
                        message: message,
                        didAttachImage: didAttachImage,
                        completionHandler: completionHandler
                    )
                }
            } catch {
                Log.w("NotificationContent", "Attachment download failed or exceeded its limit", error)
                self.completeAttachmentHandling(
                    message: message,
                    didAttachImage: false,
                    completionHandler: completionHandler
                )
            }
        }
    }

    private func attachLocalImage(from localFileUrl: URL) -> Bool {
        do {
            let notificationAttachment = try UNNotificationAttachment(identifier: "attachment", url: localFileUrl)
            attachments = attachments + [notificationAttachment]
            return true
        } catch {
            Log.w("NotificationContent", "Failed to attach local image", error)
            return false
        }
    }

    private func configureNotificationActions(message: Message, timeout: TimeInterval) {
        let userActions = message.actions ?? []
        let actions = userActions.prefix(4).map {
            UNNotificationAction(identifier: $0.id, title: $0.label, options: [.foreground])
        }

        let categoryId = UNMutableNotificationContent.actionCategoryIdentifier(for: userActions)
        let identifier = categoryId.isEmpty ? UNMutableNotificationContent.categoryPrefix + "dismiss" : categoryId
        self.categoryIdentifier = identifier

        let category = UNNotificationCategory(identifier: identifier, actions: Array(actions), intentIdentifiers: [], options: [.customDismissAction])
        UNMutableNotificationContent.registerCategorySynchronously(category, timeout: timeout)
    }

    /// A stable, cross-process notification-category identifier for a message's action set.
    ///
    /// The old code hard-coded a single global `"ntfyActions"` category and rewrote it for
    /// *every* notification, so two notifications delivered close together with different
    /// buttons clobbered each other's category — and a message could end up showing the
    /// wrong (or no) banner actions. Deriving the id from the action set instead means
    /// notifications with the same buttons share a category and ones with different buttons
    /// get distinct categories, so they can no longer overwrite each other.
    ///
    /// The hash is SHA-256 (not Swift's `Hasher`, which is seeded per-process) precisely
    /// because the main app and the Notification Service Extension are separate processes
    /// that must agree on the id for an identical action set. Only the fields that shape the
    /// rendered banner buttons — each action's identifier and title, in order, capped at the
    /// same 4 iOS renders — feed the hash. Returns `""` when there are no actions.
    /// Namespace for the categories this app registers, so pruning can tell ours apart
    /// from any category registered elsewhere.
    static let categoryPrefix = "ntfyActions."

    static func actionCategoryIdentifier(for actions: [Action]) -> String {
        let capped = actions.prefix(4)
        guard !capped.isEmpty else { return "" }
        // Delimit fields/records with control chars that can't appear in button text so
        // e.g. [("a","bc")] and [("ab","c")] hash to different categories.
        let canonical = capped
            .map { "\($0.id)\u{1f}\($0.label)" }
            .joined(separator: "\u{1e}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return categoryPrefix + hex
    }

    /// Registers `category` with the notification center *additively* — preserving every
    /// other already-registered category — and, when called off the main thread, does not
    /// return until the write has been read back. That closes the original race: the NSE
    /// used to call its `contentHandler` (delivering the banner) before the async category
    /// write landed, so the buttons were often missing on first delivery.
    ///
    /// `setNotificationCategories` has no completion handler, so registration is confirmed
    /// with a follow-up `getNotificationCategories` read-back. The wait is bounded by
    /// `timeout` so a wedged notification center can never hang notification delivery, and
    /// it is skipped on the main thread (where blocking could deadlock if the center's
    /// completion also targeted main) — every real caller (`NSE.handleMessage`, the app's
    /// background-poll path) runs this off-main.
    static func registerCategorySynchronously(_ category: UNNotificationCategory,
                                              center: UNUserNotificationCenter = .current(),
                                              timeout: TimeInterval = 3) {
        let sem = DispatchSemaphore(value: 0)
        // Garbage-collect our own stale categories before adding this one. The ntfy server
        // mints a FRESH random `id` for every action of every message (verified against a
        // live server), so `actionCategoryIdentifier` is effectively unique per notification
        // and a purely additive registration would grow without bound — re-serializing an
        // ever-larger set to the notification center on every single delivery, on the NSE's
        // critical path. A category is only needed while its notification is still on
        // screen, so keep exactly those (plus the one being registered) and drop the rest.
        // Categories that aren't ours are never touched.
        center.getDeliveredNotifications { delivered in
            let live = Set(delivered.map { $0.request.content.categoryIdentifier })
            center.getNotificationCategories { existing in
                let kept = existing.filter {
                    $0.identifier != category.identifier
                        && (!$0.identifier.hasPrefix(categoryPrefix) || live.contains($0.identifier))
                }
                center.setNotificationCategories(Set(kept).union([category]))
                // Read back to confirm the write landed before signalling.
                center.getNotificationCategories { _ in sem.signal() }
            }
        }
        guard !Thread.isMainThread else { return }
        _ = sem.wait(timeout: .now() + timeout)
    }

    private func completeAttachmentHandling(message: Message, didAttachImage: Bool, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.appendAttachmentSummaryIfNeeded(message: message, didAttachImage: didAttachImage)
            // Re-read the unread total immediately before delivery. `modify` already set it, but an
            // attachment download can hold this notification for up to 20s — long enough for a
            // second push to arrive, be delivered with a higher count, and then have this one step
            // the icon back down when it finally lands. Reading last shrinks that window to the
            // handoff itself; it cannot close it entirely, since iOS applies the badge after us.
            self.badge = NSNumber(value: Store.shared.totalUnreadCount())
            completionHandler()
        }
    }

    private func appendAttachmentSummaryIfNeeded(message: Message, didAttachImage: Bool) {
        guard let attachment = message.attachment else {
            return
        }
        if attachment.isImageAttachment(), didAttachImage {
            return
        }

        let summary = fallbackAttachmentSummary(attachment: attachment)
        guard !summary.isEmpty else {
            return
        }

        if body.isEmpty {
            body = summary
        } else {
            body = body + "\n\n" + summary
        }
    }
}

private func fallbackAttachmentSummary(attachment: MessageAttachment) -> String {
    var parts = [attachment.displayName()]
    if let size = attachment.size, size > 0 {
        parts.append(formatBytes(size))
    }
    if attachment.isExpired() {
        parts.append("expired")
    }
    return "Attachment: " + parts.joined(separator: ", ")
}

/// Select using server + topic + sequence, never request identifiers alone: APNs identifiers do
/// not equal ntfy ids, and independent servers may mint identical ids.
struct SequenceRemoval {
    let baseUrl: String
    let topic: String
    let sequence: String
    var throughTime: Int64? = nil
    var keepingID: String? = nil

    func matches(userInfo: [AnyHashable: Any]) -> Bool {
        guard let message = Message.from(userInfo: userInfo), message.event == "message",
              normalizeBaseUrl(userInfo["base_url"] as? String ?? Config.appBaseUrl) == normalizeBaseUrl(baseUrl),
              message.topic == topic, message.sequence == sequence, message.id != keepingID else { return false }
        return throughTime.map { message.time <= $0 } ?? true
    }

    func identifiers(in requests: [UNNotificationRequest]) -> [String] {
        requests.filter { matches(userInfo: $0.content.userInfo) }.map(\.identifier)
    }

    func removeDelivered() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = self.identifiers(in: notifications.map(\.request))
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

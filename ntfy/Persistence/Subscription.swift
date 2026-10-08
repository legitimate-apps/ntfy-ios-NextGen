import Foundation

extension Subscription {
    func urlString() -> String {
        return topicUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
    
    func displayName() -> String {
        if let customDisplayName = customDisplayName, !customDisplayName.isEmpty {
            return customDisplayName
        }
        return topicShortUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }

    /// The name shown on its own line in the subscription list and as the topic screen's title:
    /// the user's custom name when they set one, otherwise the bare topic. Deliberately never
    /// includes the server address — that gets its own line, so the part that identifies a topic
    /// is no longer pushed off the end by a long hostname.
    ///
    /// Distinct from `displayName()` on purpose: that one still falls back to `host/topic` because
    /// it also titles notifications, where the server is worth carrying.
    func shortDisplayName() -> String {
        let trimmed = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return topicName()
    }

    /// `host/topic` — the full address with the scheme stripped, matching how the app renders
    /// topic URLs everywhere else.
    func shortUrlString() -> String {
        return topicShortUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }

    /// Just the server, for VoiceOver: the row already announces the topic, so spelling out a
    /// whole URL after it is noise.
    func serverHost() -> String {
        return shortUrl(url: normalizeBaseUrl(baseUrl ?? "?"))
    }

    func topicName() -> String {
        return topic ?? "?"
    }

    /// Whether a push payload's raw `base_url` / `topic` refer to this subscription.
    ///
    /// Normalizes the base URL on both sides. The payload carries the server's configured
    /// `base-url` verbatim, while the stored value has been through `normalizeBaseUrl` — so a
    /// self-hosted server configured with a trailing slash produced two strings that never
    /// compared equal, and every other lookup in the app (`topicUrl`, `fetchSubscription`,
    /// tap-navigation) already normalizes first.
    func matches(baseUrl: String, topic: String) -> Bool {
        return normalizeBaseUrl(baseUrl) == normalizeBaseUrl(self.baseUrl ?? "") && topic == self.topic
    }
    
    func urlHash() -> String {
        return topicHash(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
    
    func notificationCount() -> Int {
        return notifications?.count ?? 0
    }

    /// How many notifications in this topic haven't been read yet — drives the list row's badge.
    func unreadCount() -> Int {
        guard let notifications = notifications as? Set<Notification> else { return 0 }
        return notifications.reduce(0) { $0 + ($1.read ? 0 : 1) }
    }

    func hasUnread() -> Bool {
        guard let notifications = notifications as? Set<Notification> else { return false }
        return notifications.contains { !$0.read }
    }
    
    func lastNotification() -> Notification? {
        guard let notifications else {
            return nil
        }
        return notifications
            .sortedArray(using: [NSSortDescriptor(keyPath: \Notification.time, ascending: false)])
            .first as? Notification
    }
}

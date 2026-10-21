import Foundation
import CoreData
import UserNotifications

/// A deadline is evaluated at delivery, without a timer or a change to FCM bindings.
/// nil means resumed; distantFuture is persisted for "until resumed".
enum TopicMuteDuration: String, CaseIterable, Identifiable {
    case minutes30, hour1, hours2, hours8, tomorrow, untilResumed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours8: return "8 hours"
        case .tomorrow: return "Until tomorrow, 8:30 AM"
        case .untilResumed: return "Until resumed"
        }
    }
    func deadline(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes30: return now.addingTimeInterval(30 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .hours2: return now.addingTimeInterval(2 * 60 * 60)
        case .hours8: return now.addingTimeInterval(8 * 60 * 60)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 8, minute: 30, second: 0, of: tomorrow)!
        case .untilResumed: return .distantFuture
        }
    }
}

enum TopicMute {
    static func isMuted(until: Date?, now: Date = Date()) -> Bool {
        until.map { $0 > now } ?? false
    }
    static func status(until: Date?, now: Date = Date()) -> String? {
        guard let until, isMuted(until: until, now: now) else { return nil }
        if until == .distantFuture { return "Notifications muted until resumed" }
        return "Notifications muted until " + DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short)
    }
}

extension Store {
    /// Read on a new context, so an already-running NSE sees app writes without waiting for
    /// persistent-history notifications or reusing a registered object's old snapshot.
    func isTopicMuted(baseUrl: String, topic: String, now: Date = Date()) -> Bool {
        let reader = container.newBackgroundContext()
        var muted = false
        reader.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Subscription")
            request.predicate = NSPredicate(format: "baseUrl == %@ AND topic == %@", normalizeBaseUrl(baseUrl), topic)
            request.fetchLimit = 1
            do {
                let until = try reader.fetch(request).first?.value(forKey: "mutedUntil") as? Date
                muted = TopicMute.isMuted(until: until, now: now)
            } catch {
                // A temporarily unavailable store must not let an alert bypass a user's mute.
                Log.w(Store.tag, "Cannot read topic mute; delivering quietly", error)
                muted = true
            }
        }
        return muted
    }

    func isNotificationMuted(userInfo: [AnyHashable: Any], now: Date = Date()) -> Bool {
        let topic = userInfo["topic"] as? String ?? ""
        let baseUrl = userInfo["base_url"] as? String
        if userInfo["event"] as? String == "poll_request",
           let target = findSubscriptionMatch(forPollRequestTopic: topic, preferredBaseUrl: baseUrl) {
            return isTopicMuted(baseUrl: target.baseUrl, topic: target.topic, now: now)
        }
        return isTopicMuted(baseUrl: baseUrl ?? Config.appBaseUrl, topic: topic, now: now)
    }

    func setTopicMute(until: Date?, subscription: Subscription) throws {
        var failure: Error?
        context.performAndWait {
            let previous = subscription.mutedUntil
            subscription.mutedUntil = until
            do { try context.save() }
            catch { subscription.mutedUntil = previous; failure = error }
        }
        if let failure { throw failure }
    }
}

extension UNMutableNotificationContent {
    func applyTopicMute(store: Store = .shared, now: Date = Date()) {
        guard store.isNotificationMuted(userInfo: userInfo, now: now) else { return }
        silenceTopicAlert()
    }

    /// Applied after priority mapping and again at the final delivery boundary. Badge and
    /// message content remain intact. Passive notifications stay in Notification Center.
    func applyTopicMute(baseUrl: String, topic: String, store: Store = .shared, now: Date = Date()) {
        guard store.isTopicMuted(baseUrl: baseUrl, topic: topic, now: now) else { return }
        silenceTopicAlert()
    }

    private func silenceTopicAlert() {
        sound = nil
        interruptionLevel = .passive
        relevanceScore = 0
    }
}

import Foundation
import UserNotifications

/// English copy for delivery health, shared with the notification extension.
/// Keep these together until this feature is localized.
enum DeliveryHealthCopy {
    static let notificationsOff = "Notifications are turned off for this app."
    static let openSettings = "Open Settings"
    static let allowNotifications = "Allow notifications"
    static let permissionNeeded = "Allow notifications to receive alerts."
    static let status = "Notification status"
    static let permission = "Permission"
    static let phoneRegistration = "Phone registration"
    static let pushRegistration = "Push registration"
    static let registered = "Registered"
    static let waiting = "Not registered yet"
    static let pendingTopics = "Topics waiting for push"
    static let repair = "Repair"
    static let repairing = "Repairing…"
    static let repairComplete = "Push setup is complete. This does not check delivery from your server."
    static let repairWaiting = "Push setup is still finishing. Check again in a moment."
    static let repairPending = "Push setup is still incomplete. Try again later."
    static let repairTimeout = "Repair is still running. Check again in a moment."
    static let unreachable = "Can't reach the server"
    static let unauthorized = "Sign-in failed"
    static let rateLimited = "The server is limiting requests"
    static func controlFailure(topic: String) -> String { "Open the app to update notifications for \(topic)." }
    static let otherFailure = "Couldn't refresh this topic"

    static func permissionLabel(_ state: UNAuthorizationStatus) -> String {
        switch state {
        case .denied: return "Turned off"
        case .authorized: return "Allowed"
        case .provisional: return "Quiet delivery"
        case .ephemeral: return "Allowed temporarily"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    static func fetchFailure(topic: String) -> String {
        "New message on \(topic). Open the app to load it."
    }
}

enum NotificationHealth {
    static func showsBanner(for state: UNAuthorizationStatus) -> Bool { state == .denied }

    static func repairResult(permission: UNAuthorizationStatus, registered: Bool, bindingsComplete: Bool) -> String {
        switch permission {
        case .denied: return DeliveryHealthCopy.notificationsOff
        case .notDetermined: return DeliveryHealthCopy.permissionNeeded
        case .authorized, .provisional, .ephemeral: break
        @unknown default: return DeliveryHealthCopy.permissionNeeded
        }
        guard registered else { return DeliveryHealthCopy.repairWaiting }
        return bindingsComplete ? DeliveryHealthCopy.repairComplete : DeliveryHealthCopy.repairPending
    }

    /// Overwrite every server-controlled presentation field, preserving routing metadata only.
    /// This is also the best attempt installed BEFORE fetching, so expiry cannot show ciphertext.
    static func fetchFailureContent(_ content: UNNotificationContent, topic: String, baseUrl: String? = nil, event: String = "message") -> UNMutableNotificationContent {
        let safe = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        safe.title = topic
        safe.subtitle = ""
        safe.body = event == "message_clear" || event == "message_delete"
            ? DeliveryHealthCopy.controlFailure(topic: topic) : DeliveryHealthCopy.fetchFailure(topic: topic)
        if event == "message_clear" || event == "message_delete" {
            safe.sound = nil
            safe.interruptionLevel = .passive
        }
        safe.attachments = []
        safe.categoryIdentifier = ""
        safe.userInfo.removeValue(forKey: "click")
        safe.userInfo.removeValue(forKey: "actions")
        safe.userInfo["topic"] = topic
        if let baseUrl { safe.userInfo["base_url"] = baseUrl }
        return safe
    }
}

/// Retain HTTP status and Retry-After without retaining response bodies or credentials.
struct PollHTTPError: Error {
    let status: Int
    let retryAfter: String?
}

enum PollFailure: Equatable {
    case unreachable, unauthorized, rateLimited, other

    static func classify(_ error: Error?) -> PollFailure {
        if let http = error as? PollHTTPError {
            switch http.status {
            case 401, 403: return .unauthorized
            case 429: return .rateLimited
            default: return .other
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .timedOut, .secureConnectionFailed: return .unreachable
            default: return .other
            }
        }
        return .other
    }

    var label: String {
        switch self {
        case .unreachable: return DeliveryHealthCopy.unreachable
        case .unauthorized: return DeliveryHealthCopy.unauthorized
        case .rateLimited: return DeliveryHealthCopy.rateLimited
        case .other: return DeliveryHealthCopy.otherFailure
        }
    }
}

struct TopicDeliveryHealth {
    private(set) var failure: PollFailure?
    private(set) var consecutiveFailures = 0
    var label: String? { failure?.label }
    var needsAttention: Bool { consecutiveFailures >= 3 }

    mutating func record(_ failure: PollFailure?, attempted: Bool = true) {
        self.failure = failure
        if attempted { consecutiveFailures = failure == nil ? 0 : consecutiveFailures + 1 }
    }
}

struct PollTiming {
    static let minimumInterval: TimeInterval = 30
    private(set) var nextAllowed = Date.distantPast
    private(set) var failures = 0
    private var limited = false

    func allowsPoll(now: Date, manual: Bool) -> Bool {
        now >= nextAllowed || (manual && !limited)
    }

    mutating func record(failure: PollFailure?, retryAfter: String?, now: Date) {
        failures = failure == nil ? 0 : min(failures + 1, 16)
        limited = failure == .rateLimited
        let base: TimeInterval = limited ? 60 : Self.minimumInterval
        let cap: TimeInterval = limited ? 3600 : 300
        let delay = failure == nil ? base : min(base * pow(2, Double(max(0, failures - 1))), cap)
        nextAllowed = now.addingTimeInterval(max(delay, limited ? Self.retryDelay(retryAfter, now: now) ?? 0 : 0))
    }

    /// RFC 9110: nonnegative integer delta-seconds or HTTP-date. Ignore malformed input.
    static func retryDelay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(value), seconds.isFinite {
            return min(seconds, 3600)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return min(3600, max(0, date.timeIntervalSince(now))) }
        }
        return nil
    }
}


/// One server brake shared by polls and clears. Only deadlines and the last manual probe persist.
/// A bad persisted/header deadline is bounded to an hour. Manual probes are at most once a minute.
final class ServerCooldown {
    static let shared = ServerCooldown(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let key = "deliveryHealthServerCooldowns"
    private let probeKey = "deliveryHealthServerProbes"
    private var until: [String: Double]
    private var probes: [String: Double]
    private var failures: [String: Int] = [:]
    // No request survives a launch; only the deadlines and manual-probe pacing need persistence.
    struct Attempt { fileprivate let generation: UUID? }
    private var generations: [String: UUID] = [:]

    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let date = now().timeIntervalSince1970
        until = (defaults?.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date }
            .mapValues { min($0, date + 3600) }
        probes = (defaults?.dictionary(forKey: probeKey) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date - 60 }
            .mapValues { min($0, date) }
        generations = until.mapValues { _ in UUID() }
        defaults?.set(until, forKey: key)
        defaults?.set(probes, forKey: probeKey)
    }

    func deadline(for server: String) -> Date {
        lock.lock(); defer { lock.unlock() }
        return Date(timeIntervalSince1970: until[normalizeBaseUrl(server)] ?? 0)
    }

    func claim(server: String, manual: Bool) -> Bool {
        claimAttempt(server: server, manual: manual) != nil
    }

    func claimAttempt(server: String, manual: Bool) -> Attempt? {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        let date = now().timeIntervalSince1970
        if (until[server] ?? 0) > date {
            guard manual, date - (probes[server] ?? 0) >= 60 else { return nil }
            probes[server] = date
            defaults?.set(probes, forKey: probeKey)
        }
        return Attempt(generation: generations[server])
    }

    func limit(server: String, retryAfter: String?) {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        let date = now()
        generations[server] = UUID() // A 429 invalidates older probes even if its deadline is unchanged.
        let active = (until[server] ?? 0) > date.timeIntervalSince1970
        // Concurrent failures in the same burst are one attempt, not successive retries.
        if !active { failures[server] = min((failures[server] ?? 0) + 1, 7) }
        let fallback = min(60 * pow(2, Double(max(0, (failures[server] ?? 1) - 1))), 3600)
        let delay = max(1, PollTiming.retryDelay(retryAfter, now: date) ?? fallback)
        until[server] = min(date.timeIntervalSince1970 + 3600,
            max(until[server] ?? 0, date.addingTimeInterval(delay).timeIntervalSince1970))
        until = until.filter { $0.value > date.timeIntervalSince1970 }
        defaults?.set(until, forKey: key)
    }

    func succeeded(server: String, attempt: Attempt) {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        // Clear only the brake this fetch tested, never a newer concurrent 429 from a poll or clear.
        guard generations[server] == attempt.generation else { return }
        until.removeValue(forKey: server)
        failures.removeValue(forKey: server)
        generations.removeValue(forKey: server)
        defaults?.set(until, forKey: key)
    }
}

/// Expiry always uses the latest safe presentation, including a successful fetch before attachments.
final class NotificationBestAttempt {
    private let lock = NSLock()
    private var current: UNMutableNotificationContent
    init(_ content: UNMutableNotificationContent) { current = content }
    var content: UNMutableNotificationContent {
        lock.lock(); defer { lock.unlock() }; return current
    }
    func replace(with content: UNMutableNotificationContent) {
        lock.lock(); defer { lock.unlock() }; current = content
    }
}

/// Wait up to five seconds for registration callbacks, then let reconciliation report its result.
enum RegistrationRepair {
    static func wait(isReady: @escaping () -> Bool,
                     schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: $0) },
                     remaining: Int = 10, completion: @escaping () -> Void) {
        guard !isReady(), remaining > 0 else { completion(); return }
        schedule { wait(isReady: isReady, schedule: schedule, remaining: remaining - 1, completion: completion) }
    }
}

/// A successful push fetch/ingestion also repairs an earlier row error across the app/NSE boundary.
/// These timestamps contain no message content or credentials; Core Data needs no new field.
enum DeliveryReceipt {
    static let changed = Foundation.Notification.Name("DeliveryReceiptChanged")
    static let externalChanged = "net.ntfy.deliveryHealthReceiptChanged"
    static let key = "deliveryHealthPushReceipts"
    static func identity(baseUrl: String, topic: String) -> String { topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic) }
    static func record(baseUrl: String, topic: String) {
        record(topicUrl: identity(baseUrl: baseUrl, topic: topic))
    }
    static func record(topicUrl: String) {
        let defaults = UserDefaults(suiteName: Store.appGroup) ?? .standard
        var receipts = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let date = Date().timeIntervalSince1970
        receipts = receipts.filter { $0.value > date - 86400 }
        receipts[topicUrl] = date
        defaults.set(receipts, forKey: key)
        // Publish after the cross-process defaults write, independently of the earlier database save.
        defaults.synchronize()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(externalChanged as CFString), nil, nil, true)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

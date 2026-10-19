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
    var retryCondition: String? = nil
}

/// Recognized server extensions never shorten a reset to the stock one-hour cap.
/// Unknown/malformed conditions leave the 1.17 policy in charge.
enum RetryDirective: Equatable {
    case time(TimeInterval), stateChange, requestChange

    static func parse(condition: String?, retryAfter: String?, now: Date = Date()) -> RetryDirective? {
        switch condition?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "state-change": return .stateChange
        case "request-change": return .requestChange
        case "time":
            guard let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(value), seconds.isFinite else { return nil }
            // Dispatch nanosecond deadlines cannot represent arbitrarily large intervals. Do not
            // retry such a refusal early; require an explicit new user intent instead.
            return seconds < Double(Int64.max) / 1_000_000_000 ? .time(seconds) : .requestChange
        default: return nil
        }
    }
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


/// Rate-limit gates follow the budget of the refused operation. Polls retain the bounded
/// 1.17 backoff and manual probe; publish refusals cannot suppress reads or discovery.
final class ServerCooldown {
    static let shared = ServerCooldown(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let key = "deliveryBudgetCooldowns118r2"
    private let changeKey = "deliveryBudgetChanges118r2"
    private let probeKey = "deliveryBudgetProbes118r2"
    private var until: [String: Double]
    private var monotonic: [String: Double] = [:]
    private var changes: [String: String]
    private var probes: [String: Double] = [:]
    private var failures: [String: Int] = [:]
    private var generations: [String: UUID] = [:]

    enum Kind: String { case poll, clear, clearThrough, action, publish, relay, discovery }
    struct Attempt { fileprivate let generation: UUID?; fileprivate let kind: Kind }
    private func scope(_ server: String, _ kind: Kind) -> String {
        let budget: String
        switch kind {
        case .clear, .clearThrough, .action, .publish: budget = "publish"
        default: budget = kind.rawValue
        }
        return normalizeBaseUrl(server) + "|118|" + budget
    }

    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.now = now; self.uptime = uptime
        let date = now().timeIntervalSince1970
        until = (defaults?.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date }
            .mapValues { min($0, date + 86400) }
        // A pre-1.18 stock brake can safely migrate to polling for at most an hour.
        for (server, deadline) in defaults?.dictionary(forKey: "deliveryHealthServerCooldowns") as? [String: Double] ?? [:] {
            if deadline.isFinite && deadline > date { until[normalizeBaseUrl(server) + "|118|poll"] = min(deadline, date + 3600) }
        }
        for name in Array(until.keys) where name.hasSuffix("|118|poll") { until[name] = min(until[name]!, date + 3600) }
        changes = [:]
        probes = (defaults?.dictionary(forKey: probeKey) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date - 60 }.mapValues { min($0, date) }
        changes = (defaults?.dictionary(forKey: changeKey) as? [String: String] ?? [:])
            .filter { ["state-change", "request-change"].contains($0.value) && until[$0.key] != nil }
        for (name, deadline) in until where !name.hasSuffix("|118|poll") && changes[name] == nil {
            monotonic[name] = uptime() + deadline - date
        }
        generations = until.mapValues { _ in UUID() }
        // Initialization also runs in the NSE. Read and bound old snapshots without writing
        // them over a newer app refusal; migration is committed by the next actual mutation.
    }

    private func active(_ name: String) -> Bool {
        if let deadline = monotonic[name] { return deadline > uptime() }
        return (until[name] ?? 0) > now().timeIntervalSince1970
    }
    private func persist() {
        defaults?.set(until, forKey: key); defaults?.set(changes, forKey: changeKey); defaults?.set(probes, forKey: probeKey)
        defaults?.removeObject(forKey: "serverExtensionCooldowns118")
        defaults?.removeObject(forKey: "serverExtensionChanges118")
        defaults?.removeObject(forKey: "deliveryHealthServerCooldowns")
    }

    /// Discovery must never spend a manual-refresh probe while any budget is paused.
    func isLimited(server: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let prefix = normalizeBaseUrl(server) + "|118|"
        return until.keys.contains { $0.hasPrefix(prefix) && active($0) }
    }

    func deadline(for server: String, kind: Kind = .poll) -> Date {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, kind)
        if let deadline = monotonic[name] { return now().addingTimeInterval(max(0, deadline - uptime())) }
        return Date(timeIntervalSince1970: until[name] ?? 0)
    }

    func claim(server: String, manual: Bool, kind: Kind = .poll, consumingProbe: Bool = true) -> Bool {
        claimAttempt(server: server, manual: manual, kind: kind, consumingProbe: consumingProbe) != nil
    }
    func claimAttempt(server: String, manual: Bool, kind: Kind = .poll, consumingProbe: Bool = true) -> Attempt? {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, kind)
        if active(name) {
            // Timed publish resets are honored in full. Polls always keep 1.17's manual probe.
            guard manual, kind == .poll || changes[name] != nil,
                  now().timeIntervalSince1970 - (probes[name] ?? 0) >= 60 else { return nil }
            if consumingProbe { probes[name] = now().timeIntervalSince1970; persist() }
        }
        return Attempt(generation: generations[name], kind: kind)
    }

    func limit(server: String, retryAfter: String?, condition: String? = nil, kind: Kind = .poll) {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, kind), date = now()
        generations[name] = UUID() // A newer refusal invalidates an older concurrent success.
        let directive = RetryDirective.parse(condition: condition, retryAfter: retryAfter, now: date)
        if kind != .poll, let directive {
            let delay: TimeInterval
            switch directive {
            case .time(let seconds):
                changes.removeValue(forKey: name)
                // No timer is scheduled for long waits. Bound persisted poison to a day.
                delay = min(86400, max(1, seconds))
                monotonic[name] = max(monotonic[name] ?? 0, uptime() + delay)
            case .stateChange: delay = 86400; changes[name] = "state-change"; monotonic.removeValue(forKey: name)
            case .requestChange: delay = 86400; changes[name] = "request-change"; monotonic.removeValue(forKey: name)
            }
            until[name] = max(until[name] ?? 0, date.timeIntervalSince1970 + delay)
        } else {
            // Even a recognized non-time poll refusal recovers on the stock 60s exponential
            // policy. A supplied timed delay is capped just as in 1.17, including manual probes.
            if !active(name) { failures[name] = min((failures[name] ?? 0) + 1, 7) }
            let fallback = min(60 * pow(2, Double(max(0, (failures[name] ?? 1) - 1))), 3600)
            let delay = max(1, PollTiming.retryDelay(retryAfter, now: date) ?? fallback)
            until[name] = min(date.timeIntervalSince1970 + 3600,
                max(until[name] ?? 0, date.timeIntervalSince1970 + delay))
            changes.removeValue(forKey: name)
            monotonic.removeValue(forKey: name)
        }
        persist()
    }

    func hasNonTimeRefusal(server: String, kind: Kind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, kind)
        return active(name) && changes[name] != nil
    }
    func requestChanged(server: String, kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, kind)
        if changes[name] == "request-change" {
            changes.removeValue(forKey: name); until.removeValue(forKey: name); monotonic.removeValue(forKey: name)
            persist()
        }
    }
    func succeeded(server: String, attempt: Attempt) {
        lock.lock(); defer { lock.unlock() }
        let name = scope(server, attempt.kind)
        guard generations[name] == attempt.generation else { return }
        until.removeValue(forKey: name); monotonic.removeValue(forKey: name); changes.removeValue(forKey: name)
        failures.removeValue(forKey: name); generations.removeValue(forKey: name)
        persist()
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

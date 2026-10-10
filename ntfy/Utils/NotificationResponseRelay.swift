import Foundation
import UserNotifications

/// A banner tap the Notification Service Extension received instead of the app, parked in the App
/// Group until the app picks it up.
struct RelayedNotificationResponse: Codable, Equatable {
    let notificationId: String
    let actionIdentifier: String
    let userInfo: [String: String]
    let receivedAt: Date
}

/// Gets banner taps to the app when the system hands them to the extension.
///
/// On a Mac running the iOS app ("Designed for iPad/iPhone"), usernoted delivers a notification
/// response to a UserNotifications client of the app's bundle, and that client can be the
/// extension process still alive from rendering the banner rather than the app. Observed on macOS
/// 2026-10-09: `Notifying UserNotifications client <bundle>:<pid of ntfyNSE> about response`. The
/// extension had no delegate, so every banner tap (an "Approve" button, a plain click) was
/// dropped while the app was only brought to the front.
///
/// The extension can't open URLs, show the app's UI or reach its in-process state, so it doesn't
/// run the action itself: it records the response here and posts a Darwin notification. The app
/// drains the queue when it launches, becomes active (the system brings it forward for any
/// foreground action) or hears that notification, and runs the response through the same path as
/// `userNotificationCenter(_:didReceive:)`.
final class NotificationResponseRelay: NSObject, UNUserNotificationCenterDelegate {
    /// The extension's instance. `UNUserNotificationCenter.delegate` is weak, so something has to own it.
    static let shared = NotificationResponseRelay(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)

    static let darwinNotificationName = "\(Store.appGroup).notificationResponseRelayed"
    static let defaultsKey = "relayedNotificationResponses"
    /// A tap older than this is stale: the request it answered (an approval window) is long over.
    static let maxAge: TimeInterval = 10 * 60
    /// Bounds the queue if the app never runs to drain it.
    static let maxQueued = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Only the Mac routes responses to the extension. On iPhone and iPad the app receives them
    /// directly, so the extension leaves the delegate alone and that path is unchanged.
    static func installInExtensionIfNeeded(isiOSAppOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) {
        guard isiOSAppOnMac else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    // MARK: Extension side

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        enqueue(RelayedNotificationResponse(
            notificationId: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: Self.stringValues(response.notification.request.content.userInfo),
            receivedAt: Date()
        ))
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotificationName as CFString),
            nil, nil, true
        )
        completionHandler()
    }

    // MARK: Queue

    func enqueue(_ response: RelayedNotificationResponse) {
        var queued = load()
        queued.append(response)
        save(Array(queued.suffix(Self.maxQueued)))
    }

    /// Removes and returns every queued response still young enough to act on, oldest first.
    func drain(now: Date = Date()) -> [RelayedNotificationResponse] {
        let queued = load()
        guard !queued.isEmpty else { return [] }
        save([])
        return queued.filter { now.timeIntervalSince($0.receivedAt) <= Self.maxAge }
    }

    /// The ntfy fields `Message.from(userInfo:)` reads are all strings; anything else (the `aps`
    /// dictionary, numbers) isn't needed and may not survive the property-list round trip.
    static func stringValues(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String {
                result[key] = value
            }
        }
        return result
    }

    private func load() -> [RelayedNotificationResponse] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RelayedNotificationResponse].self, from: data)) ?? []
    }

    private func save(_ responses: [RelayedNotificationResponse]) {
        if responses.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(responses) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        // The extension may end its process right after a tap (see `NotificationExtensionLifetime`).
        defaults.synchronize()
    }
}

/// Ends the extension process on a Mac shortly after its last notification is delivered.
///
/// macOS keeps the extension process alive but suspended after it delivers a banner, and
/// usernoted still routes that banner's taps to it. Observed 2026-10-09 on build 27: an Approve
/// tap was relayed only when the next push woke the extension, minutes later; with the extension
/// process gone, the same tap reached the app in the same second. So once nothing is in flight,
/// the extension exits and taps go to the app. A tap that arrives before the exit still goes
/// through `NotificationResponseRelay`. iPhone and iPad route taps to the app already, so there
/// the process is left to the system.
final class NotificationExtensionLifetime {
    static let shared = NotificationExtensionLifetime()
    /// Long enough for usernoted to take the delivered content; far shorter than a human tap.
    static let exitDelay: TimeInterval = 1

    private let enabled: Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let exitProcess: () -> Void
    private let lock = NSLock()
    private var inFlight = 0
    private var generation = 0

    init(
        enabled: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        exitProcess: @escaping () -> Void = { exit(0) }
    ) {
        self.enabled = enabled
        self.schedule = schedule
        self.exitProcess = exitProcess
    }

    /// A notification request arrived; any scheduled exit is off until it is delivered.
    func requestStarted() {
        lock.lock()
        defer { lock.unlock() }
        inFlight += 1
        generation += 1
    }

    /// A request's content was delivered. The last one schedules the exit.
    func requestFinished() {
        guard enabled else { return }
        lock.lock()
        inFlight = max(0, inFlight - 1)
        guard inFlight == 0 else { lock.unlock(); return }
        generation += 1
        let scheduled = generation
        lock.unlock()
        schedule(Self.exitDelay) { [self] in
            lock.lock()
            defer { lock.unlock() }
            // Held through the exit so a request starting on another thread can't slip in between.
            if inFlight == 0 && generation == scheduled {
                exitProcess()
            }
        }
    }
}

/// Runs each notification response once, whichever process received it. The app's own delegate
/// and the relay could in principle both report the same tap; the second report is dropped.
struct NotificationResponseDeduper {
    static let window: TimeInterval = 10 * 60
    private var handled: [String: Date] = [:]

    /// Returns true the first time a (notification, action) pair is seen within the window.
    mutating func shouldHandle(notificationId: String, actionIdentifier: String, now: Date = Date()) -> Bool {
        handled = handled.filter { now.timeIntervalSince($0.value) < Self.window }
        let key = notificationId + "\u{1F}" + actionIdentifier
        guard handled[key] == nil else { return false }
        handled[key] = now
        return true
    }
}

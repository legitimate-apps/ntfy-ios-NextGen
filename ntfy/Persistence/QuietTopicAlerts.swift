import Foundation
import UserNotifications
import CryptoKit
import Darwin

/// One non-repeating request per permanent subscription identity. The app and NSE share choices,
/// but neither needs to execute when a quiet alert becomes due.
final class QuietTopicAlerts {
    static let shared = QuietTopicAlerts(defaults: UserDefaults(suiteName: Config.appGroupId)!,
        directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupId))
    static let marker = "quiet_topic"
    static let intervals: [TimeInterval] = [900, 3600, 21600, 86400]
    var bundle: Bundle = .main
    let defaults: UserDefaults
    private let directory: URL?
    private let queue = DispatchQueue(label: "ntfy.quiet-topics")
    private let pending = DispatchGroup()
    private var jobs: [(UUID, QuietSchedulingOperation, () -> Void)] = []
    private var activeID: UUID?
    private let operationsLock = NSLock()
    private var operations: [UUID: QuietSchedulingOperation] = [:]
    var schedule: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void = {
        UNUserNotificationCenter.current().add($0, withCompletionHandler: $1)
    }
    var remove: ([String]) -> Void = {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
    }
    /// The app installs a UIKit background-task wrapper. Extensions use their request lifetime.
    var beginExecution: (@escaping () -> Void, @escaping (@escaping () -> Void) -> Void) -> Void = { _, start in start({}) }

    init(defaults: UserDefaults, directory: URL?) {
        self.defaults = defaults
        self.directory = directory
    }

    static func identifier(_ identity: String) -> String {
        "quietTopic.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func interval(for identity: String) -> TimeInterval {
        defaults.synchronize()
        return (defaults.dictionary(forKey: Self.identifier(identity))?["interval"] as? Double) ?? 0
    }

    static func intervalTitle(_ interval: TimeInterval, bundle: Bundle = .main) -> String {
        switch interval {
        case 900: return String(localized: "15 minutes", bundle: bundle)
        case 3600: return String(localized: "1 hour", bundle: bundle)
        case 21600: return String(localized: "6 hours", bundle: bundle)
        default: return String(localized: "24 hours", bundle: bundle)
        }
    }

    func configure(identity: String, baseUrl: String, topic: String, title: String,
                   interval: TimeInterval, completion: @escaping (Error?) -> Void = { _ in }) {
        update(identity: identity, completion: completion) { previous in
            guard interval > 0 else { return nil }
            var state = previous ?? [:]
            if let previous, let received = previous["received"] as? Double,
               let oldInterval = previous["interval"] as? Double {
                // An elapsed one-shot has done its job. Editing its interval does not re-arm it.
                state["awaitingMessage"] = previous["awaitingMessage"] as? Bool == true
                    || received + oldInterval <= Date().timeIntervalSince1970
            }
            state["interval"] = interval
            state["baseUrl"] = baseUrl
            state["topic"] = topic
            state["title"] = title
            // Enabling starts a fresh window. Changing the interval keeps the last receipt anchor.
            if previous == nil { state["received"] = Date().timeIntervalSince1970 }
            return state
        }
    }

    func received(identity: String) {
        guard interval(for: identity) > 0 else { return }
        let received = Date().timeIntervalSince1970
        update(identity: identity) { previous in
            guard var state = previous else { return nil }
            state["received"] = max(state["received"] as? Double ?? 0, received)
            state["awaitingMessage"] = false
            return state
        }
    }

    func cancel(identity: String) {
        update(identity: identity) { _ in nil }
    }

    /// Normal NSE delivery waits for its scheduling callbacks before handing execution to iOS.
    /// Expiry deliberately bypasses this wait, just as it bypasses database and alert locks.
    func flush(_ completion: @escaping () -> Void) { pending.notify(queue: queue, execute: completion) }

    func cancelScheduling() {
        operationsLock.lock()
        let active = Array(operations.values)
        operationsLock.unlock()
        active.forEach { $0.finish(POSIXError(.ECANCELED)) }
    }

    private func runNext() {
        guard activeID == nil else { return }
        while !jobs.isEmpty {
            let (id, operation, work) = jobs.removeFirst()
            guard !operation.isFinished else { continue }
            activeID = id
            work()
            break
        }
    }

    private func update(identity: String, completion: @escaping (Error?) -> Void = { _ in },
                        transform: @escaping ([String: Any]?) -> [String: Any]?) {
        pending.enter()
        let id = UUID()
        let operation = QuietSchedulingOperation()
        operationsLock.lock(); operations[id] = operation; operationsLock.unlock()
        beginExecution({ operation.finish(POSIXError(.ECANCELED)) }) { endExecution in
            operation.onFinish = { error in
                self.operationsLock.lock(); self.operations.removeValue(forKey: id); self.operationsLock.unlock()
                self.pending.leave()
                endExecution()
                completion(error)
                self.queue.async {
                    if self.activeID == id { self.activeID = nil; self.runNext() }
                }
            }
            let work = {
                let key = Self.identifier(identity)
                let deadline = Date().addingTimeInterval(5)
                func finish(_ error: Error?) { operation.finish(error) }
                func attempt() {
                    guard !operation.isFinished else { return }
                    if let directory = self.directory {
                        switch operation.acquire(directory.appendingPathComponent("quietTopics.v1.lock")) {
                        case -1: finish(POSIXError(.EIO)); return
                        case 1:
                            guard Date() < deadline else { finish(POSIXError(.ETIMEDOUT)); return }
                            self.queue.asyncAfter(deadline: .now() + 0.02, execute: attempt)
                            return
                        default: break
                        }
                    }
                    self.defaults.synchronize()
                    let previous = self.defaults.dictionary(forKey: key)
                    guard let state = transform(previous) else {
                        self.defaults.removeObject(forKey: key)
                        self.defaults.synchronize()
                        self.remove([key])
                        finish(nil)
                        return
                    }
                    self.defaults.set(state, forKey: key)
                    self.defaults.synchronize()
                    if state["awaitingMessage"] as? Bool == true {
                        self.remove([key])
                        finish(nil)
                        return
                    }
                    let interval = state["interval"] as? Double ?? 0
                    let received = state["received"] as? Double ?? Date().timeIntervalSince1970
                    let content = UNMutableNotificationContent()
                    content.title = state["title"] as? String ?? state["topic"] as? String ?? ""
                    let duration = Self.intervalTitle(interval, bundle: self.bundle)
                    content.body = String(localized: "No message received for \(duration).", bundle: self.bundle)
                    content.sound = .default
                    content.interruptionLevel = .active
                    content.userInfo = [Self.marker: true, "base_url": state["baseUrl"] as? String ?? "", "topic": state["topic"] as? String ?? ""]
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, received + interval - Date().timeIntervalSince1970), repeats: false)
                    self.schedule(UNNotificationRequest(identifier: key, content: content, trigger: trigger)) { error in
                        self.queue.async {
                            guard !operation.isFinished else { return }
                            if let error {
                                // Retain the prior choice if changing it failed, so the UI can retry.
                                if let previous { self.defaults.set(previous, forKey: key) }
                                else { self.defaults.removeObject(forKey: key) }
                                self.defaults.synchronize()
                                Log.w("QuietTopicAlerts", "Cannot schedule quiet topic alert", error)
                            }
                            finish(error)
                        }
                    }
                    // Do not leave a shared lock behind if the system never calls the scheduler back.
                    self.queue.asyncAfter(deadline: .now() + 5) { finish(POSIXError(.ETIMEDOUT)) }
                }
                attempt()
            }
            self.queue.async {
                self.jobs.append((id, operation, work))
                self.runNext()
            }
        }
    }
}

/// Cancellation releases the file descriptor synchronously, without waiting on the scheduling
/// queue or reading shared preferences. This also serves the NSE expiry path.
private final class QuietSchedulingOperation {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var result: Error??
    private var callback: ((Error?) -> Void)?
    private let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Schedule quiet topic alert")
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    var onFinish: ((Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set {
            lock.lock(); callback = newValue; let completed = result; lock.unlock()
            if let completed { newValue?(completed) }
        }
    }
    func acquire(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return -1 }
        if descriptor < 0 { descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { return -1 }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return 0 }
        return errno == EWOULDBLOCK || errno == EAGAIN ? 1 : -1
    }
    func finish(_ error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .some(error)
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
        let finished = callback
        lock.unlock()
        ProcessInfo.processInfo.endActivity(activity)
        finished?(error)
    }
}

import Foundation
import Combine

final class DeliveryHealthMonitor: ObservableObject {
    static let shared = DeliveryHealthMonitor(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard, observeExternalReceipts: true)
    @Published private(set) var topics: [String: TopicDeliveryHealth] = [:]
    @Published private(set) var known: Set<String> = []
    private let defaults: UserDefaults?
    private var identities: [String: String] = [:]
    private var failedAt: [String: Double] = [:]
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults? = nil, observeExternalReceipts: Bool = false) {
        self.defaults = defaults
        if observeExternalReceipts {
            // Only the process-lifetime singleton observes Darwin notifications; no object pointer
            // crosses processes, and publication stays on the main thread.
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
                { _, _, _, _, _ in
                    DispatchQueue.main.async { DeliveryHealthMonitor.shared.refreshReceipts() }
                }, DeliveryReceipt.externalChanged as CFString, nil, .deliverImmediately)
        }
        for name in [Store.didChangeRemotely, DeliveryReceipt.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshReceipts()
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func register(_ request: PollRequest) {
        let update = { self.identities[request.subscriptionID.uriRepresentation().absoluteString] = request.topicUrl }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func healthy(keys: [String]) -> Bool { !keys.isEmpty && keys.allSatisfy { known.contains($0) && topics[$0] == nil } }

    func received(key: String) { record(key: key, failure: nil) }

    func refreshReceipts() {
        defaults?.synchronize()
        let receipts = defaults?.dictionary(forKey: DeliveryReceipt.key) as? [String: Double] ?? [:]
        for (key, identity) in identities where topics[key] != nil {
            if (receipts[identity] ?? 0) > (failedAt[key] ?? .greatestFiniteMagnitude) { received(key: key) }
        }
    }

    func record(key: String, failure: PollFailure?, attempted: Bool = true) {
        let update = {
            if attempted { self.known.insert(key) }
            if failure == nil {
                if self.topics[key] != nil { self.topics.removeValue(forKey: key) }
                self.failedAt.removeValue(forKey: key)
            } else {
                var state = self.topics[key] ?? TopicDeliveryHealth()
                state.record(failure, attempted: attempted)
                self.topics[key] = state
                self.failedAt[key] = Date().timeIntervalSince1970
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
}

/// The list alone uses the minimum interval. Live reads, test sends and silent wakes need fresh
/// answers. Every caller joins an existing fetch and respects the shared server rate-limit brake.
final class PollCoordinator {
    static let shared = PollCoordinator(cooldown: .shared)
    private let lock = NSLock()
    private let now: () -> Date
    let cooldown: ServerCooldown
    private var timing: [String: PollTiming] = [:]
    private struct Waiting {
        let presenting: Bool
        let completion: (PollOutcome) -> Void
    }
    private var callbacks: [String: [Waiting]] = [:]

    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.cooldown = ServerCooldown(defaults: defaults, now: now)
    }
    init(cooldown: ServerCooldown, now: @escaping () -> Date = Date.init) {
        self.now = now; self.cooldown = cooldown
    }

    func begin(_ request: PollRequest, manual: Bool, automaticList: Bool = false, presenting: Bool = false, completion: @escaping (PollOutcome) -> Void) -> Bool {
        DeliveryHealthMonitor.shared.register(request)
        lock.lock()
        let key = request.subscriptionID.uriRepresentation().absoluteString
        if callbacks[key] != nil {
            callbacks[key]?.append(Waiting(presenting: presenting, completion: completion))
            lock.unlock()
            return false
        }
        let limited = !cooldown.claim(server: request.baseUrl, manual: manual)
        if limited || (automaticList && !(timing[key] ?? PollTiming()).allowsPoll(now: now(), manual: manual)) {
            lock.unlock()
            // A skipped request is neither success/new data nor another failed attempt.
            if limited { DeliveryHealthMonitor.shared.record(key: key, failure: .rateLimited, attempted: false) }
            completion(PollOutcome(succeeded: false, newMessages: [], failure: limited ? .rateLimited : nil, attempted: false))
            return false
        }
        callbacks[key] = [Waiting(presenting: presenting, completion: completion)]
        lock.unlock()
        return true
    }

    func finish(_ request: PollRequest, outcome: PollOutcome, retryAfter: String?) {
        lock.lock()
        let key = request.subscriptionID.uriRepresentation().absoluteString
        var policy = timing[key] ?? PollTiming()
        policy.record(failure: outcome.failure, retryAfter: retryAfter, now: now())
        timing[key] = policy
        if outcome.failure == .rateLimited { cooldown.limit(server: request.baseUrl, retryAfter: retryAfter) }
        else if outcome.succeeded { cooldown.succeeded(server: request.baseUrl) }
        let waiting = callbacks.removeValue(forKey: key) ?? []
        lock.unlock()
        DeliveryHealthMonitor.shared.record(key: key, failure: outcome.failure)
        var presentationClaimed = false
        for waiter in waiting {
            var result = outcome
            if waiter.presenting {
                if presentationClaimed { result = PollOutcome(succeeded: outcome.succeeded, newMessages: [], failure: outcome.failure) }
                presentationClaimed = true
            }
            waiter.completion(result)
        }
    }
}

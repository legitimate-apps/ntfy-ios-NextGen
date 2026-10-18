import Foundation

/// Manager to combine persisting a subscription to the data store and subscribing to Firebase.
/// This is to centralize the logic in one place.
struct SubscriptionManager {
    private let tag = "SubscriptionManager"
    var store: Store
    var reconciler: FcmSubscriptionReconciler = .shared
    var polling: PollCoordinator = .shared
    /// The network call behind a poll; a seam so tests can answer without a server.
    var fetch: (PollRequest, @escaping ([Message]?, Error?) -> Void) -> Void = { ApiService.shared.poll($0, timeout: 10, completionHandler: $1) }

    /// A hashed upstream topic is public and forgeable. Its payload is only a wake hint: never
    /// ingest it, including its base_url, sequence_id or event ID. Poll snapshots of our own
    /// subscriptions instead. Saving the response applies controls/updates without presenting
    /// new alerts; the background caller allows eight seconds per request and at most one replay.
    @discardableResult
    func handleSilentWake(userInfo: [AnyHashable: Any], completion: @escaping (Bool) -> Void) -> Bool {
        guard let event = userInfo["event"] as? String,
              event == "message_clear" || event == "message_delete",
              let topic = userInfo["topic"] as? String else { return false }
        var requests: [PollRequest] = []
        store.context.performAndWait {
            requests = (store.getSubscriptions() ?? []).compactMap { subscription in
                guard let baseUrl = subscription.baseUrl, let realTopic = subscription.topic,
                      normalizeBaseUrl(baseUrl) != normalizeBaseUrl(Config.appBaseUrl),
                      firebaseTopic(baseUrl: baseUrl, topic: realTopic) == topic else { return nil }
                return store.pollRequest(for: subscription)
            }
        }
        guard !requests.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var succeeded = false
        for request in requests {
            group.enter()
            guard polling.begin(request, manual: false, completion: { outcome in
                if outcome.succeeded { lock.lock(); succeeded = true; lock.unlock() }
                group.leave()
            }) else { continue }
            let finish: (Bool, Error?) -> Void = { saved, error in
                polling.finish(request, outcome: PollOutcome(succeeded: saved, newMessages: [],
                    failure: saved ? nil : PollFailure.classify(error)), retryAfter: (error as? PollHTTPError)?.retryAfter)
            }
            fetch(request) { messages, error in
                guard let messages, store.save(notificationsFromMessages: messages, polledWith: request) != nil else {
                    finish(false, error)
                    return
                }
                if request.since != nil, let ordered = store.reconciliationRequest(after: request) {
                    fetch(ordered) { messages, error in
                        finish(messages.map { store.save(notificationsFromMessages: $0, polledWith: ordered) != nil } ?? false, error)
                    }
                } else {
                    finish(true, nil)
                }
            }
        }
        group.notify(queue: .main) { completion(succeeded) }
        return true
    }

    func subscribe(baseUrl: String, topic: String) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        Log.d(tag, "Subscribing to \(topicUrl(baseUrl: normalizedBaseUrl, topic: topic))")
        // Persist first. The row is created with `fcmSubscribed == false`, which
        // makes it the retry queue: if the FCM binding below fails (or never even
        // gets attempted because the APNs token hasn't landed yet), the next
        // reconcile picks it up. Previously the subscribe was fire-and-forget and
        // the row was saved regardless, so a single failure meant this topic
        // never received push again — ntfy#1305.
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        reconciler.reconcile(reason: "subscribed to \(topic)")
        poll(subscription)
    }

    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        DispatchQueue.main.async {
            // Read the identity out, delete the row, and only then tear down the FCM binding.
            //
            // The old order — tear down first, delete after — assumed the completion could not run
            // before the delete. Nothing guarantees that: `FcmTopicSubscriber` permits a synchronous
            // completion (the test fake is synchronous), and a teardown completion re-checks whether
            // the topic is live. Seeing the not-yet-deleted row, it would mark it stale and
            // reconcile — rebinding the topic — and the delete would then land, leaving a live FCM
            // binding with no subscription behind it. A ghost binding is exactly what this teardown
            // exists to prevent.
            let baseUrl = subscription.baseUrl
            let topic = subscription.topic
            guard store.delete(subscription: subscription) else {
                // The row is still there, so the user still has this subscription. Tearing down its
                // FCM binding now would split the two states: the row returns on the next refresh
                // or relaunch, still reading `fcmSubscribed = true`, so reconciliation skips it and
                // the user is left with a visible subscription whose push is silently dead.
                Log.w(tag, "Not tearing down FCM for \(topic ?? "?") — the subscription failed to delete")
                return
            }
            if let baseUrl = baseUrl, let topic = topic {
                reconciler.unsubscribe(baseUrl: baseUrl, topic: topic)
            }
        }
    }
    
    func poll(_ subscription: Subscription) {
        pollWithOutcome(subscription) { _ in }
    }

    func poll(_ subscription: Subscription, completionHandler: @escaping ([Message]) -> Void) {
        pollWithOutcome(subscription, presenting: true) { outcome in completionHandler(outcome.newMessages) }
    }

    /// The request is built from a snapshot taken on the store's context (URL, cursor, credentials,
    /// object ID), so the network callback never touches the managed `Subscription`. The response is
    /// saved against the object ID, re-resolved on the context; if the topic was unsubscribed in the
    /// meantime the response is dropped.
    ///
    /// The live loop skips an overlapping tick; explicit refresh joins an existing request and
    /// waits for its result. Only automatic list polls use the minimum interval; every caller
    /// respects server rate limits, with one manual probe per minute. Saves still de-duplicate by ID and never move cursors backward.
    func pollWithOutcome(_ subscription: Subscription, skipIfInFlight: Bool = false, manual: Bool = false, automaticList: Bool = false, presenting: Bool = false, completionHandler: @escaping (PollOutcome) -> Void) {
        guard let request = store.pollRequest(for: subscription) else {
            Log.d(tag, "Attempting to poll dead subscription failed")
            completionHandler(PollOutcome(succeeded: false, newMessages: []))
            return
        }
        if skipIfInFlight {
            guard PollGuard.shared.begin(key: request.topicUrl) else {
                Log.d(tag, "Skipping live poll of \(request.topicUrl): one is already in flight")
                completionHandler(PollOutcome(succeeded: false, newMessages: [], attempted: false))
                return
            }
        }
        let release = { if skipIfInFlight { PollGuard.shared.end(key: request.topicUrl) } }
        guard polling.begin(request, manual: manual, automaticList: automaticList, presenting: presenting, completion: { outcome in
            release()
            completionHandler(outcome)
        }) else { return }
        let store = self.store
        let tag = self.tag
        Log.d(tag, "Polling from \(request.topicUrl) with user \(request.user?.username ?? "anonymous")")
        fetch(request) { messages, error in
            guard let messages = messages else {
                Log.e(tag, "Polling failed", error)
                polling.finish(request, outcome: PollOutcome(succeeded: false, newMessages: [], failure: PollFailure.classify(error)),
                               retryAfter: (error as? PollHTTPError)?.retryAfter)
                return
            }
            // Report only what was actually stored. The server can re-deliver messages we already
            // have; notifying for those re-alerts the user about a message they have already seen.
            let newMessages = store.save(notificationsFromMessages: messages, polledWith: request)
            if let newMessages {
                Log.d(tag, "Polling success, \(messages.count) message(s), \(newMessages.count) new", newMessages)
            }
            polling.finish(request, outcome: PollOutcome(succeeded: newMessages != nil, newMessages: newMessages ?? [],
                           failure: newMessages == nil ? .other : nil), retryAfter: nil)
        }
    }

    /// Completion includes saves and all outcomes, rather than only enqueueing the requests.
    func pollAll(_ subscriptions: [Subscription], manual: Bool, completion: @escaping () -> Void) {
        let launch = {
            guard !subscriptions.isEmpty else { completion(); return }
            // Round robin across servers so a large dead server cannot hold healthy ones behind it.
            var groups = Dictionary(grouping: subscriptions, by: { normalizeBaseUrl($0.baseUrl ?? "") })
            let servers = groups.keys.sorted()
            var ordered: [Subscription] = []
            while !groups.isEmpty {
                for server in servers {
                    if var group = groups[server], !group.isEmpty {
                        ordered.append(group.removeFirst())
                        groups[server] = group.isEmpty ? nil : group
                    }
                }
            }
            var failedServers: Set<String> = []
            var next = 0
            var remaining = ordered.count
            func startNext() {
                guard next < ordered.count else { return }
                let subscription = ordered[next]
                let server = normalizeBaseUrl(subscription.baseUrl ?? "")
                next += 1
                if failedServers.contains(server) {
                    DeliveryHealthMonitor.shared.record(key: subscription.objectID.uriRepresentation().absoluteString, failure: .unreachable, attempted: false)
                    remaining -= 1
                    if remaining == 0 { completion() } else { startNext() }
                    return
                }
                pollWithOutcome(subscription, manual: manual, automaticList: !manual) { outcome in
                    DispatchQueue.main.async {
                        if outcome.failure == .unreachable { failedServers.insert(server) }
                        remaining -= 1
                        if remaining == 0 { completion() } else { startNext() }
                    }
                }
            }
            // A large list must not burst every topic at the server at once. A rate-limit
            // response is recorded before the next queued topic reaches the shared gate.
            for _ in 0..<min(4, subscriptions.count) { startNext() }
        }
        if Thread.isMainThread { launch() } else { DispatchQueue.main.async(execute: launch) }
    }

    func pollAll(_ subscriptions: [Subscription], manual: Bool) async {
        await withCheckedContinuation { continuation in
            pollAll(subscriptions, manual: manual) { continuation.resume() }
        }
    }

}

struct PollOutcome {
    let succeeded: Bool
    let newMessages: [Message]
    var failure: PollFailure? = nil
    var attempted = true
}

/// At most one live-loop poll in flight per topic. Without it the open topic's ten-second timer
/// piled requests up behind a slow server (requests may take 30 s), all fetching the same window.
final class PollGuard {
    static let shared = PollGuard()

    private let lock = NSLock()
    private var running: Set<String> = []

    /// Claims `key`; false if a poll for it is already running.
    func begin(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running.insert(key).inserted
    }

    func end(key: String) {
        lock.lock(); defer { lock.unlock() }
        running.remove(key)
    }
}

/// How often an open topic checks for new messages: every 10 s while polls succeed, doubling after
/// each consecutive failure up to 5 minutes, so an unreachable server isn't hammered.
enum LivePollSchedule {
    static let interval: TimeInterval = 10
    static let maxInterval: TimeInterval = 300

    static func failures(after outcome: PollOutcome, previous: Int) -> Int {
        guard outcome.attempted else { return previous }
        return outcome.succeeded ? 0 : previous + 1
    }

    static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        let exponent = Double(min(max(failures, 0), 16))
        return min(interval * pow(2, exponent), maxInterval)
    }
}

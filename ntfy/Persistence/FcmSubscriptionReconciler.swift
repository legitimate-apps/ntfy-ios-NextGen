import Foundation
import FirebaseMessaging

/// Abstracts the Firebase Messaging topic API.
///
/// FCM delivery cannot be exercised on the simulator (no APNs, no FCM), so the
/// *decision* logic — which topics still need subscribing, and when it is even
/// legal to try — lives in `FcmSubscriptionReconciler` behind this seam. Tests
/// inject a fake and assert on the calls we make; the network hop stays
/// device-only.
protocol FcmTopicSubscriber {
    /// FCM can only bind a topic to this device once the APNs token has been
    /// handed to Firebase. Subscribing before that fails for every topic.
    var hasApnsToken: Bool { get }
    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void)
    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void)
}

struct FirebaseTopicSubscriber: FcmTopicSubscriber {
    var hasApnsToken: Bool { Messaging.messaging().apnsToken != nil }

    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
        Messaging.messaging().subscribe(toTopic: topic, completion: completion)
    }

    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) {
        Messaging.messaging().unsubscribe(fromTopic: topic, completion: completion)
    }
}

/// Keeps the device's FCM topic subscriptions in sync with the subscriptions the
/// user actually has (ntfy#1305).
///
/// The bug this replaces: both `subscribe(toTopic:)` call sites were
/// fire-and-forget — they logged failures and moved on, while the Core Data row
/// was persisted regardless. A single transient failure (APNs token not yet
/// associated, network blip, FCM hiccup) left the app *looking* subscribed and
/// polling fine on refresh, while push was silently dead forever. Reinstalling
/// was the only repair, because it forced a fresh token and a clean re-subscribe
/// round.
///
/// The fix is to treat FCM subscription as *reconciled state* rather than a
/// one-shot side effect:
///   * every subscription carries `fcmSubscribed`, false until FCM confirms it;
///   * `reconcile()` re-fires only the ones still false, and is safe to call as
///     often as we like;
///   * it runs on APNs-token arrival, FCM-token arrival, and every foreground,
///     so a desynced device self-heals instead of needing a reinstall;
///   * a failure simply leaves the flag false, so the next reconcile retries —
///     no timers, no backoff bookkeeping.
final class FcmSubscriptionReconciler {
    private let tag = "FcmReconciler"

    /// Poll requests from the server arrive on this topic. It is not a user
    /// subscription, so its state lives in defaults rather than Core Data.
    static let pollTopic = "~poll" // See ntfy server if ever changed

    private static let defaultsKeyLastFcmToken = "lastFcmRegistrationToken"
    private static let defaultsKeyPollSubscribed = "pollTopicFcmSubscribed"
    /// The app base URL (`Config.appBaseUrl`) the current topic bindings were named under. Absent on
    /// every install that predates it, which is treated as "changed".
    static let defaultsKeyBindingsAppBaseUrl = "fcmBindingsAppBaseUrl"

    static let shared = FcmSubscriptionReconciler(store: Store.shared)

    private let store: Store
    private let subscriber: FcmTopicSubscriber
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var inFlight = false
    /// Set when a reconcile is asked for while a round is in flight, so the request is
    /// honoured after that round instead of being dropped.
    private var rerunRequested = false
    /// Obsolete names this process already tried to tear down (`drainObsoleteTopicNames`).
    private var drainAttempted: Set<String> = []

    init(store: Store,
         subscriber: FcmTopicSubscriber = FirebaseTopicSubscriber(),
         defaults: UserDefaults = UserDefaults(suiteName: Store.appGroup) ?? .standard) {
        self.store = store
        self.subscriber = subscriber
        self.defaults = defaults
    }

    /// Record the FCM registration token and invalidate everything if it changed.
    ///
    /// This is the half the original code got structurally wrong. FCM binds
    /// topics to a *token*, so when the token rotates every prior subscription
    /// is void — but the old code only re-subscribed opportunistically and
    /// nothing recorded whether the round worked. Tracking the last-seen token
    /// means a rotation reliably marks all topics stale, and reconciliation then
    /// rebuilds them (with retries) instead of hoping one pass succeeded.
    ///
    /// Returns true if the token was new (i.e. state was invalidated).
    @discardableResult
    func noteRegistrationToken(_ token: String?) -> Bool {
        guard let token = token, !token.isEmpty else {
            Log.w(tag, "FCM registration token missing; leaving subscription state untouched")
            return false
        }
        let previous = defaults.string(forKey: Self.defaultsKeyLastFcmToken)
        guard previous != token else { return false }

        Log.d(tag, "FCM token changed (\(previous?.prefix(12) ?? "none")... -> \(token.prefix(12))...); "
                 + "marking all topic subscriptions stale")
        // One atomic invalidation: bump the generation, reset the poll flag, mark every row stale.
        // Subscribe calls already in flight were issued against the previous token, so letting their
        // confirmations mark topics subscribed would undo this staleness — and because the flags
        // would then read `true`, no later reconcile would rebuild them.
        //
        // Doing it as separate steps was not enough, in two different ways. Resetting the poll flag
        // before the bump let an old-token confirmation set it back to true, and nothing resets it
        // again, so the new token would never bind `~poll`. Bumping before the reset fixed that but
        // left the mirror-image hole: a *new*-generation round could start in between, see the
        // not-yet-reset state, find no work and finish, with nothing scheduled afterwards. Only one
        // critical section closes both.
        store.invalidateAllFcmSubscriptions {
            defaults.set(token, forKey: Self.defaultsKeyLastFcmToken)
            defaults.set(false, forKey: Self.defaultsKeyPollSubscribed)
        }
        // And drive the rebuild from here rather than relying on the caller. Every caller happens to
        // reconcile immediately afterwards today, but this method's contract is "everything is now
        // stale" — leaving the round that acts on it to a convention is how the hole above got in.
        reconcile(reason: "FCM registration token rotated")
        return true
    }

    /// Re-subscribe every topic FCM has not confirmed for the current token.
    ///
    /// Safe and cheap to call repeatedly: with nothing pending it is a fetch and
    /// a return. Callers do not need to know whether the APNs token has landed —
    /// if it hasn't, this no-ops and the APNs callback drives the retry.
    func reconcile(reason: String) {
        guard subscriber.hasApnsToken else {
            // Not an error: `didReceiveRegistrationToken` routinely beats
            // `didRegisterForRemoteNotifications...`. Whichever lands second
            // re-drives us, so we just wait rather than burning a failed round.
            Log.d(tag, "reconcile(\(reason)) deferred — APNs token not associated with Firebase yet")
            return
        }

        drainObsoleteTopicNames()

        // Rename first: a round that bound names derived from a different app base URL would only
        // confirm topics no server publishes to. A rename drives its own round, so stop here if it ran.
        if rebindIfAppBaseUrlChanged() { return }

        lock.lock()
        if inFlight {
            // Remember the request rather than dropping it: the in-flight round may have
            // been started before whatever prompted this call (most importantly a token
            // rotation), so it cannot be assumed to cover it.
            rerunRequested = true
            lock.unlock()
            Log.d(tag, "reconcile(\(reason)) queued — a round is already in flight")
            return
        }
        inFlight = true
        lock.unlock()

        let roundGeneration = store.fcmGeneration()

        var work: [(topic: String, confirm: () -> Void)] = []

        if !defaults.bool(forKey: Self.defaultsKeyPollSubscribed) {
            work.append((Self.pollTopic, { [weak self] in
                self?.defaults.set(true, forKey: Self.defaultsKeyPollSubscribed)
            }))
        }

        for subscription in store.getSubscriptionsPendingFcmSubscribe() {
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { continue }
            let name = firebaseTopic(baseUrl: baseUrl, topic: topic)
            work.append((name, { [weak self] in
                self?.store.setFcmSubscribed(subscription, true)
            }))
        }

        guard !work.isEmpty else {
            Log.d(tag, "reconcile(\(reason)): nothing pending")
            finish()
            return
        }

        Log.d(tag, "reconcile(\(reason)): (re-)subscribing \(work.count) topic(s)")
        let group = DispatchGroup()
        for item in work {
            group.enter()
            subscriber.subscribe(toTopic: item.topic) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    // Leave the flag false on purpose — that IS the retry queue.
                    Log.e(self.tag,
                          "Firebase subscribe failed for \(item.topic); will retry on next reconcile", error)
                } else if !self.store.withCurrentFcmGeneration(roundGeneration, item.confirm) {
                    // The check and the write happen in one critical section on the Core Data queue,
                    // so a confirmation cannot slip past an invalidation that lands beside it. Two
                    // things invalidate: the registration token rotated (this binding belongs to the
                    // old token), or a teardown for this topic settled after the subscribe was
                    // dispatched (FCM may have applied them in that order, so the binding is gone).
                    // Either way the flag stays false and the next round rebuilds it.
                    Log.d(self.tag,
                          "Ignoring stale confirmation for \(item.topic) — it was superseded while in flight")
                } else {
                    Log.d(self.tag, "Firebase subscribe confirmed for \(item.topic)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.finish()
        }
    }

    /// Move every binding to the names the current app base URL implies, if it changed.
    ///
    /// A subscription's FCM topic name depends on the app's built-in server: the raw topic when the
    /// subscription is on that server, otherwise the hash of its URL (`firebaseTopic`). So when the
    /// built-in server changes (1.14 moved it to ntfy-me.com) the *names* change for existing rows —
    /// on the old server raw→hash, on the new one hash→raw — while their `fcmSubscribed` flags still
    /// read true for the old names. Without this, reconciliation finds nothing to do and push is
    /// silently dead for every existing subscription.
    ///
    /// Each subscription's other possible name is torn down, except any name some subscription now
    /// needs: `x` on the new built-in server needs raw `x`, which is exactly the old name of `x` on the
    /// previous one. Every row is then marked stale and the base URL recorded in one critical section,
    /// and the round that rebinds them is driven from here. A teardown that fails (offline) only
    /// leaves a stray binding behind; it never holds up binding the new names.
    ///
    /// Returns true if the bindings were invalidated (and a rebuild round requested).
    @discardableResult
    func rebindIfAppBaseUrlChanged() -> Bool {
        let current = normalizeBaseUrl(Config.appBaseUrl)
        let recorded = defaults.string(forKey: Self.defaultsKeyBindingsAppBaseUrl).map(normalizeBaseUrl)
        guard recorded != current else { return false }

        let pairs: [(baseUrl: String, topic: String)] = (store.getSubscriptions() ?? []).compactMap {
            guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
            return (baseUrl, topic)
        }
        let needed = Set(pairs.map { firebaseTopic(baseUrl: $0.baseUrl, topic: $0.topic) })
        let superseded = Set(pairs.map { pair -> String in
            let name = firebaseTopic(baseUrl: pair.baseUrl, topic: pair.topic)
            return name == pair.topic ? topicHash(baseUrl: pair.baseUrl, topic: pair.topic) : pair.topic
        }).subtracting(needed)

        Log.d(tag, "App base URL changed (\(recorded ?? "never recorded") -> \(current)); rebinding "
                 + "\(pairs.count) subscription(s), tearing down \(superseded.count) superseded name(s)")
        store.invalidateAllFcmSubscriptions {
            defaults.set(current, forKey: Self.defaultsKeyBindingsAppBaseUrl)
        }
        superseded.sorted().forEach { teardown($0) }
        reconcile(reason: "app base URL changed")
        return true
    }

    // MARK: Obsolete names (durable teardown queue)

    /// FCM names that some earlier state bound and nothing needs any more, waiting to be torn down.
    /// Persisted, because the binding outlives the process: `RetiredDefaultServerMigration` queues a
    /// moved row's old names before saving the move, so a launch killed in between still cleans up.
    static let defaultsKeyPendingObsoleteTopicNames = "pendingObsoleteFcmTopicNames"

    static func pendingObsoleteTopicNames(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: defaultsKeyPendingObsoleteTopicNames) ?? []
    }

    static func setPendingObsoleteTopicNames(_ names: [String], defaults: UserDefaults) {
        if names.isEmpty {
            defaults.removeObject(forKey: defaultsKeyPendingObsoleteTopicNames)
        } else {
            defaults.set(Array(Set(names)).sorted(), forKey: defaultsKeyPendingObsoleteTopicNames)
        }
    }

    static func enqueueObsoleteTopicNames(_ names: [String], defaults: UserDefaults) {
        setPendingObsoleteTopicNames(pendingObsoleteTopicNames(defaults: defaults) + names, defaults: defaults)
    }

    /// Tear down each queued name no current subscription needs. An entry leaves the queue only after
    /// FCM confirms the teardown and a fresh read shows nothing needs it, or when a current
    /// subscription binds it (then there is nothing to tear down); a failure keeps it for the next
    /// launch. Each name is tried at most once per process, because a settled teardown drives a
    /// reconcile, which would otherwise retry a failing one in a tight loop.
    private func drainObsoleteTopicNames() {
        let pending = Self.pendingObsoleteTopicNames(defaults: defaults)
        guard !pending.isEmpty, let needed = namesNeededBySubscriptions() else { return }
        lock.lock()
        // A name a current subscription binds has nothing to tear down, so it leaves the queue.
        if pending.contains(where: needed.contains) {
            Self.setPendingObsoleteTopicNames(pending.filter { !needed.contains($0) }, defaults: defaults)
        }
        let due = pending.filter { !needed.contains($0) && !drainAttempted.contains($0) }
        drainAttempted.formUnion(due)
        lock.unlock()
        guard !due.isEmpty else { return }
        Log.d(tag, "Tearing down \(due.count) obsolete FCM name(s)")
        for name in due {
            teardown(name) { [weak self] error in
                guard let self = self, error == nil,
                      let needed = self.namesNeededBySubscriptions(), !needed.contains(name) else { return }
                self.lock.lock()
                Self.setPendingObsoleteTopicNames(
                    Self.pendingObsoleteTopicNames(defaults: self.defaults).filter { $0 != name },
                    defaults: self.defaults)
                self.lock.unlock()
            }
        }
    }

    /// The FCM names current subscriptions bind, or nil when the store cannot be read (then nothing
    /// is torn down).
    private func namesNeededBySubscriptions() -> Set<String>? {
        var names: Set<String>?
        store.context.performAndWait {
            names = store.getSubscriptions().map { subscriptions in
                Set(subscriptions.compactMap { subscription -> String? in
                    guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
                    return firebaseTopic(baseUrl: baseUrl, topic: topic)
                })
            }
        }
        return names
    }

    /// Drop a topic's FCM binding. Used when the user removes a subscription.
    func unsubscribe(baseUrl: String, topic: String) {
        teardown(firebaseTopic(baseUrl: baseUrl, topic: topic))
    }

    private func teardown(_ name: String, settled: ((Error?) -> Void)? = nil) {
        subscriber.unsubscribe(fromTopic: name) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                Log.e(self.tag, "Firebase unsubscribe failed for \(name)", error)
            } else {
                Log.d(self.tag, "Firebase unsubscribe succeeded for \(name)")
            }
            settled?(error)
            self.invalidateConfirmationsSupersededBy(name)
        }
    }

    /// A teardown for `name` has settled, so any subscribe confirmation still in flight is no
    /// longer trustworthy.
    ///
    /// FCM can apply a subscribe and a teardown in either order relative to when their callbacks
    /// arrive. If it applied a subscribe first and this teardown second, the binding that
    /// confirmation is about to report is already gone — and writing `fcmSubscribed = true` for it
    /// would leave the flag reading confirmed for a binding that does not exist, which no later
    /// reconcile would rebuild. That is silent, permanent push death: the ntfy#1305 failure mode
    /// reached from a different direction.
    ///
    /// Bumping the generation makes every in-flight confirmation fail its check, and because the
    /// check and the write share the Core Data queue there is no window between them. Topics that
    /// were merely along for the ride stay stale and are re-subscribed by the round below; a
    /// redundant subscribe costs nothing, a lost binding costs everything.
    private func invalidateConfirmationsSupersededBy(_ name: String) {
        store.bumpFcmGeneration()
        // If the user re-subscribed while this teardown was in flight, the topic must be bound
        // again — the teardown may well have removed the binding a concurrent round just made.
        if store.markFcmSubscriptionStale(firebaseTopicName: name) {
            Log.d(tag, "Topic \(name) is subscribed again after its teardown settled; rebuilding")
        }
        // Reconcile unconditionally, even when this topic is gone for good. The bump above rejected
        // every confirmation in flight, not just this topic's — an unrelated topic and `~poll` can
        // have been mid-round and had their confirmations dropped. Without a successor round they
        // stay stale with nothing scheduled to fix them, and push stays down until some unrelated
        // event happens to reconcile. If a round is active this only sets `rerunRequested`, so it
        // costs exactly one follow-up pass.
        reconcile(reason: "teardown settled for \(name)")
    }

    private func finish() {
        lock.lock()
        inFlight = false
        let shouldRerun = rerunRequested
        rerunRequested = false
        lock.unlock()
        if shouldRerun {
            reconcile(reason: "queued while a round was in flight")
        }
    }
}

import XCTest
@testable import ntfy

final class FcmTeardownLedgerTests: XCTestCase {
    /// Remote application and callback delivery are independent. Tests can apply A, bind again,
    /// enqueue B, then deliver A's callback. Subscribe callbacks can also arrive out of order.
    private final class Subscriber: FcmTopicSubscriber {
        struct Failure: Error {}
        struct Call {
            let name: String
            let callback: (Error?) -> Void
        }
        var hasApnsToken = true
        var bindings: Set<String> = []
        var unsubscribes: [Call] = []
        var subscribes: [Call] = []
        var delaySubscribe = false
        func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
            bindings.insert(topic)
            subscribes.append(Call(name: topic, callback: completion))
            if !delaySubscribe { completion(nil) }
        }
        func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) {
            unsubscribes.append(Call(name: topic, callback: completion))
        }
        func apply(_ index: Int) {
            guard unsubscribes.indices.contains(index) else { XCTFail("Missing teardown request \(index)"); return }
            bindings.remove(unsubscribes[index].name)
        }
        func complete(_ index: Int, error: Error? = nil) {
            guard unsubscribes.indices.contains(index) else { XCTFail("Missing teardown request \(index)"); return }
            unsubscribes[index].callback(error)
        }
    }

    private var store: Store { Store.shared }
    private var defaults: UserDefaults!
    private var suite: String!
    private var time = Date()

    override func setUp() {
        super.setUp()
        store.getSubscriptions()?.forEach { store.delete(subscription: $0) }
        suite = "FcmTeardownTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(Config.appBaseUrl, forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl)
        defaults.set(true, forKey: "pollTopicFcmSubscribed")
    }
    override func tearDown() {
        drain()
        store.getSubscriptions()?.forEach { store.delete(subscription: $0) }
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func drain() {
        let done = expectation(description: "queued subscribe rounds finish")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 3)
    }
    private func reconciler(_ fake: Subscriber, liveness: (() -> Set<String>?)? = nil) -> FcmSubscriptionReconciler {
        FcmSubscriptionReconciler(store: store, subscriber: fake, defaults: defaults,
                                  now: { self.time }, teardownLiveness: liveness)
    }
    private func ledger(_ report: @escaping (String) -> Void = { _ in }) -> FcmTeardownLedger {
        FcmTeardownLedger(defaults: defaults, now: { self.time }, report: report)
    }
    private func live(_ topic: String = "alerts") -> Subscription {
        store.saveSubscription(baseUrl: Config.appBaseUrl, topic: topic)
    }

    func testOldSuccessCannotEraseNewerIntentAfterFreshBinding() throws {
        let fake = Subscriber()
        let r = reconciler(fake)
        fake.bindings.insert("alerts")
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let a = try XCTUnwrap(r.teardownLedger.entries.first)
        fake.apply(0) // A applied, callback held.
        let row = live()
        r.reconcile(reason: "subscribe again")
        drain()
        XCTAssertTrue(fake.bindings.contains("alerts"))
        XCTAssertTrue(store.delete(subscription: row))
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let b = try XCTUnwrap(r.teardownLedger.entries.first)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(fake.unsubscribes.count, 1, "A still owns the request slot")
        fake.complete(0)
        drain()
        XCTAssertEqual(r.teardownLedger.entries.first?.id, b.id, "A's callback must preserve B's identity")
        XCTAssertEqual(fake.unsubscribes.count, 2, "B gets its own remote teardown")
        fake.apply(1)
        fake.complete(1)
        drain()
        XCTAssertFalse(fake.bindings.contains("alerts"))
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
    }

    func testStaleLivenessCannotEraseNewerIntent() throws {
        let fake = Subscriber()
        let journal = ledger()
        let a = try XCTUnwrap(journal.record("alerts"))
        let row = live()
        var b: FcmTeardownLedger.Entry?
        let r = reconciler(fake, liveness: {
            // Core Data said live, then main deleted the row and recorded a newer intent.
            XCTAssertTrue(self.store.delete(subscription: row))
            b = journal.record("alerts")
            return ["alerts"]
        })
        r.reconcile(reason: "stale snapshot")
        drain()
        XCTAssertNotEqual(a.id, b?.id)
        XCTAssertEqual(journal.entries.first?.id, b?.id, "liveness may retire A only, never B")
        XCTAssertEqual(journal.entries.first?.attempts, 0)
    }

    func testNewIntentBetweenLiveRepairAndRetirementKeepsItsIdentity() throws {
        let fake = Subscriber()
        let journal = ledger()
        let a = try XCTUnwrap(journal.record("alerts"))
        let row = live()
        store.setFcmSubscribed(row, true)
        var b: FcmTeardownLedger.Entry?
        // This save notification lands after markFcmSubscriptionStale read the live row but
        // before the reconciler can retire A. Mutate once in willSave, without a nested save.
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave,
                                                               object: store.context, queue: nil) { _ in
            guard b == nil else { return }
            b = journal.record("alerts")
            self.store.context.delete(row)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let r = reconciler(fake)
        r.reconcile(reason: "live repair races newer unsubscribe")
        drain()
        XCTAssertNotEqual(a.id, b?.id)
        XCTAssertNil(store.getSubscription(baseUrl: Config.appBaseUrl, topic: "alerts"))
        XCTAssertEqual(journal.entries.first?.id, b?.id,
                       "a successful stale write is still not authority to retire a newer intent")
        XCTAssertEqual(journal.entries.first?.attempts, 0)
    }

    func testFailureRetriesOnLaterReconcileAndClearsOnlyAfterSuccess() throws {
        let fake = Subscriber()
        let r = reconciler(fake)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let id = try XCTUnwrap(r.teardownLedger.entries.first?.id)
        fake.complete(0, error: Subscriber.Failure())
        drain()
        XCTAssertEqual(r.teardownLedger.entries.first?.id, id)
        XCTAssertEqual(r.teardownLedger.entries.first?.attempts, 1)
        r.reconcile(reason: "foreground before backoff")
        XCTAssertEqual(fake.unsubscribes.count, 1)
        time.addTimeInterval(30)
        r.reconcile(reason: "later foreground")
        XCTAssertEqual(fake.unsubscribes.count, 2)
        XCTAssertEqual(r.teardownLedger.entries.first?.attempts, 2)
        fake.complete(1)
        drain()
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
    }

    func testResubscribeCancelsPendingRetryAndKeepsBinding() {
        let fake = Subscriber()
        let r = reconciler(fake)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        fake.complete(0, error: Subscriber.Failure())
        drain()
        let row = live()
        time.addTimeInterval(60)
        r.reconcile(reason: "resubscribed")
        drain()
        XCTAssertEqual(fake.unsubscribes.count, 1)
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
        XCTAssertTrue(row.fcmSubscribed)
        XCTAssertTrue(fake.bindings.contains("alerts"))
    }

    func testLateTeardownRepairsResubscribeForSuccessAndUnknownOutcome() {
        for error in [nil, Subscriber.Failure()] as [Error?] {
            let fake = Subscriber()
            let r = reconciler(fake)
            r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
            let row = live()
            r.reconcile(reason: "resubscribe while teardown held")
            drain()
            XCTAssertTrue(row.fcmSubscribed)
            fake.apply(0) // A late remote teardown destroys the fresh binding.
            fake.complete(0, error: error)
            drain()
            XCTAssertTrue(fake.bindings.contains("alerts"), "even an error can follow a remote teardown")
            XCTAssertTrue(row.fcmSubscribed)
            XCTAssertTrue(store.delete(subscription: row))
        }
    }

    func testRelaunchRebuildsLiveBindingWithUnconfirmedTeardownMarker() throws {
        let oldTransport = Subscriber()
        var oldProcess: FcmSubscriptionReconciler? = reconciler(oldTransport)
        oldProcess!.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let intent = try XCTUnwrap(oldProcess!.teardownLedger.entries.first)
        let row = live()
        oldProcess!.reconcile(reason: "resubscribe before teardown callback")
        drain()
        XCTAssertTrue(row.fcmSubscribed)
        XCTAssertEqual(oldProcess!.teardownLedger.entries.first?.id, intent.id,
                       "an outstanding remote outcome must retain a durable repair marker")
        oldTransport.apply(0) // Applied remotely, but process dies without receiving its callback.
        oldProcess = nil
        let newTransport = Subscriber()
        let next = reconciler(newTransport)
        next.reconcile(reason: "cold launch with live row and unconfirmed teardown")
        drain()
        XCTAssertTrue(newTransport.bindings.contains("alerts"))
        XCTAssertTrue(row.fcmSubscribed)
        XCTAssertTrue(next.teardownLedger.entries.isEmpty)
        XCTAssertTrue(newTransport.unsubscribes.isEmpty)
    }

    func testLateTeardownRejectsSubscribeConfirmationInFlight() {
        let fake = Subscriber()
        let r = reconciler(fake)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let row = live()
        fake.delaySubscribe = true
        r.reconcile(reason: "resubscribe")
        fake.apply(0)
        fake.complete(0)
        fake.delaySubscribe = false
        fake.subscribes[0].callback(nil)
        drain()
        XCTAssertGreaterThanOrEqual(fake.subscribes.filter { $0.name == "alerts" }.count, 2)
        XCTAssertTrue(fake.bindings.contains("alerts"))
        XCTAssertTrue(row.fcmSubscribed)
    }

    func testMissingCallbackReleasesRequestSlotAndLateCallbackKeepsNewIntent() throws {
        let fake = Subscriber()
        let r = reconciler(fake)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        time.addTimeInterval(121)
        r.reconcile(reason: "request timed out")
        XCTAssertEqual(fake.unsubscribes.count, 2)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        let b = try XCTUnwrap(r.teardownLedger.entries.first)
        fake.complete(0)
        XCTAssertEqual(r.teardownLedger.entries.first?.id, b.id)
        XCTAssertEqual(fake.unsubscribes.count, 2, "A's late callback cannot release the newer request slot")
        fake.complete(1)
        XCTAssertEqual(r.teardownLedger.entries.first?.id, b.id)
        XCTAssertEqual(fake.unsubscribes.count, 3)
    }

    func testBackoffPersistsAcrossLaunchAndGrowsToOneHourCap() throws {
        let journal = ledger()
        let entry = try XCTUnwrap(journal.record("alerts"))
        for delay: TimeInterval in [30, 60, 120, 240, 480, 960, 1920, 3600, 3600] {
            XCTAssertTrue(journal.attempt(try XCTUnwrap(journal.entries.first)))
            let reopened = ledger()
            let current = try XCTUnwrap(reopened.entries.first)
            XCTAssertEqual(current.id, entry.id)
            XCTAssertEqual(current.retryDelay, delay)
            time.addTimeInterval(delay - 1)
            XCTAssertFalse(reopened.attempt(current))
            time.addTimeInterval(1)
            XCTAssertTrue(current.isDue(at: time))
        }
    }

    func testExpiryLogsAndPersistsReleaseDiagnosticWithoutExpiringNewIntent() throws {
        var messages: [String] = []
        let journal = ledger { messages.append($0) }
        let old = try XCTUnwrap(journal.record("alerts"))
        XCTAssertTrue(journal.attempt(old))
        time.addTimeInterval(FcmTeardownLedger.horizon - 1)
        XCTAssertFalse(journal.expire(old))
        time.addTimeInterval(1)
        XCTAssertTrue(journal.expire(try XCTUnwrap(journal.entries.first)))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertEqual(messages.count, 1)
        let message = try XCTUnwrap(messages.first)
        XCTAssertTrue(message.contains(old.id.uuidString))
        XCTAssertTrue(message.contains("1 attempts"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: FcmTeardownLedger.key))) as? [String: Any])
        XCTAssertEqual(json["givenUpCount"] as? Int, 1)
        XCTAssertNotNil(json["lastGiveUp"])
        let newer = try XCTUnwrap(journal.record("alerts"))
        XCTAssertFalse(journal.expire(old))
        XCTAssertEqual(journal.entries.first?.id, newer.id)
    }

    func testExpiredIntentIsNotDispatched() {
        let fake = Subscriber()
        let r = reconciler(fake)
        _ = r.prepareUnsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        time.addTimeInterval(FcmTeardownLedger.horizon)
        r.reconcile(reason: "expired")
        XCTAssertTrue(fake.unsubscribes.isEmpty)
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
    }

    func testKnownLegacyArraysMigrateOnceWithoutReplacingCurrentIdentity() throws {
        defaults.set(["alerts", "alerts"], forKey: "pendingFcmUnsubscribes")
        defaults.set(["old-hash", "alerts"], forKey: "pendingObsoleteFcmTopicNames")
        let journal = ledger()
        let imported = journal.entries
        XCTAssertEqual(Set(imported.map(\.name)), ["alerts", "old-hash"])
        XCTAssertEqual(Set(imported.map(\.id)).count, 2)
        XCTAssertTrue(imported.allSatisfy { $0.created == time && $0.attempts == 0 && $0.lastAttempt == nil })
        XCTAssertNil(defaults.object(forKey: "pendingFcmUnsubscribes"))
        XCTAssertNil(defaults.object(forKey: "pendingObsoleteFcmTopicNames"))
        let current = try XCTUnwrap(journal.record("alerts"))
        defaults.set(["alerts"], forKey: "pendingFcmUnsubscribes")
        XCTAssertEqual(ledger().entries.first { $0.name == "alerts" }?.id, current.id)
    }

    func testUnknownLegacyAndVersionedFormatsArePreservedExactly() throws {
        let unknownLegacy: [String: Any] = ["future": ["intent": 99]]
        defaults.set(unknownLegacy, forKey: "pendingFcmUnsubscribes")
        let unknown = Data("{\"version\":2,\"entries\":{\"alerts\":\"future-intent\"}}".utf8)
        defaults.set(unknown, forKey: FcmTeardownLedger.key)
        let journal = ledger()
        let entry = try XCTUnwrap(journal.record("new-topic"))
        XCTAssertEqual(journal.entries.first?.id, entry.id)
        XCTAssertEqual(defaults.dictionary(forKey: "pendingFcmUnsubscribes") as NSDictionary?, unknownLegacy as NSDictionary)
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(FcmTeardownLedger.key + ".preserved.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.first?.value as? Data, unknown)
    }

    func testObsoleteNamesShareIntentIdentityAndBackoff() throws {
        let fake = Subscriber()
        let a = try XCTUnwrap(FcmSubscriptionReconciler.enqueueObsoleteTopicNames(["old-name"], defaults: defaults).first?.entry)
        let r = reconciler(fake)
        r.reconcile(reason: "obsolete")
        let b = try XCTUnwrap(FcmSubscriptionReconciler.enqueueObsoleteTopicNames(["old-name"], defaults: defaults).first?.entry)
        XCTAssertNotEqual(a.id, b.id)
        fake.complete(0)
        XCTAssertEqual(r.teardownLedger.entries.first?.id, b.id)
        fake.complete(1, error: Subscriber.Failure())
        drain()
        r.reconcile(reason: "backoff")
        XCTAssertEqual(fake.unsubscribes.count, 2)
        time.addTimeInterval(30)
        r.reconcile(reason: "retry")
        XCTAssertEqual(fake.unsubscribes.count, 3)
    }

    func testWriteAheadSurvivesRelaunchAfterDeleteBeforeDispatch() throws {
        let fake = Subscriber()
        let r = reconciler(fake)
        let row = live()
        let intent = try XCTUnwrap(r.prepareUnsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts"))
        XCTAssertTrue(store.delete(subscription: row))
        let next = reconciler(fake)
        XCTAssertEqual(next.teardownLedger.entries.first?.id, intent.id)
        next.reconcile(reason: "launch after interrupted removal")
        XCTAssertEqual(fake.unsubscribes.map(\.name), ["alerts"])
        fake.complete(0)
        XCTAssertTrue(next.teardownLedger.entries.isEmpty)
    }

    func testWriteAheadWithoutDeleteIsCancelledByLiveness() {
        let fake = Subscriber()
        let r = reconciler(fake)
        let row = live()
        _ = r.prepareUnsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        r.reconcile(reason: "launch after interrupted save")
        drain()
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
        XCTAssertTrue(fake.unsubscribes.isEmpty)
        XCTAssertTrue(row.fcmSubscribed)
    }

    func testMigrationRollbackRestoresPriorIdentityWithoutOverwritingNewIntent() throws {
        let journal = ledger()
        let a = try XCTUnwrap(journal.record("old-name", obsolete: true))
        let b = try XCTUnwrap(journal.recordChange("old-name", obsolete: true))
        journal.rollback(b)
        XCTAssertEqual(journal.entries.first?.id, a.id)
        let c = try XCTUnwrap(journal.recordChange("old-name", obsolete: true))
        let newer = try XCTUnwrap(journal.record("old-name"))
        journal.rollback(c)
        XCTAssertEqual(journal.entries.first?.id, newer.id)
    }

    func testSubscriptionManagerJournalsDeletionBeforeDispatchAndRetriesFailure() throws {
        let fake = Subscriber()
        let r = reconciler(fake)
        var manager = SubscriptionManager(store: store)
        manager.reconciler = r
        let row = live()
        manager.unsubscribe(row)
        drain()
        XCTAssertNil(store.getSubscription(baseUrl: Config.appBaseUrl, topic: "alerts"))
        XCTAssertEqual(fake.unsubscribes.count, 1)
        let intent = try XCTUnwrap(r.teardownLedger.entries.first)
        fake.complete(0, error: Subscriber.Failure())
        drain()
        XCTAssertEqual(r.teardownLedger.entries.first?.id, intent.id)
        time.addTimeInterval(30)
        r.reconcile(reason: "foreground retry after actual manager deletion")
        XCTAssertEqual(fake.unsubscribes.count, 2)
    }

    func testFailedSubscriptionDeleteCancelsOnlyItsWriteAheadIntent() {
        let fake = Subscriber()
        let r = reconciler(fake)
        var manager = SubscriptionManager(store: store)
        manager.reconciler = r
        let row = live()
        // Real Core Data save validation failure rolls the deletion back.
        _ = User(context: store.context)
        manager.unsubscribe(row)
        drain()
        XCTAssertNotNil(store.getSubscription(baseUrl: Config.appBaseUrl, topic: "alerts"))
        XCTAssertTrue(r.teardownLedger.entries.isEmpty)
        XCTAssertTrue(fake.unsubscribes.isEmpty)
    }

    func testNoApnsTokenKeepsIntentWithoutSpendingAttempt() {
        let fake = Subscriber()
        fake.hasApnsToken = false
        let r = reconciler(fake)
        r.unsubscribe(baseUrl: Config.appBaseUrl, topic: "alerts")
        XCTAssertEqual(r.teardownLedger.entries.first?.attempts, 0)
        XCTAssertTrue(fake.unsubscribes.isEmpty)
        fake.hasApnsToken = true
        r.reconcile(reason: "APNs token")
        XCTAssertEqual(fake.unsubscribes.count, 1)
    }
}

import XCTest
import UserNotifications
import Darwin
@testable import ntfy

final class QuietTopicAlertTests: XCTestCase {
    private var suite: String!
    private var root: URL!
    private var alerts: QuietTopicAlerts!
    private var requests: [String: UNNotificationRequest] = [:]
    private var removals: [String] = []

    override func setUpWithError() throws {
        suite = "QuietTopicTests." + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        alerts = QuietTopicAlerts(defaults: UserDefaults(suiteName: suite)!, directory: root)
        alerts.schedule = { request, done in self.requests[request.identifier] = request; done(nil) }
        alerts.remove = { ids in self.removals += ids; ids.forEach { self.requests.removeValue(forKey: $0) } }
    }
    override func tearDownWithError() throws {
        flush()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func flush() {
        let done = expectation(description: "quiet scheduler finished")
        alerts.flush { done.fulfill() }; wait(for: [done], timeout: 8)
    }
    private func configure(_ interval: TimeInterval, identity: String = "first") {
        alerts.configure(identity: identity, baseUrl: "https://monitor.example", topic: "monitor", title: "Garden", interval: interval)
        flush()
    }
    private func request(_ id: String = "first") throws -> UNNotificationRequest {
        try XCTUnwrap(requests[QuietTopicAlerts.identifier(id)])
    }
    func testEnableCreatesOneOrdinaryOneShotWithRoutingAndDefaultSound() throws {
        configure(900)
        let req = try request()
        XCTAssertEqual(req.content.title, "Garden")
        XCTAssertEqual(req.content.body, "No message received for 15 minutes.")
        XCTAssertEqual(req.content.interruptionLevel, .active)
        XCTAssertEqual(req.content.sound, .default)
        XCTAssertNil(req.content.badge)
        XCTAssertEqual(req.content.userInfo[QuietTopicAlerts.marker] as? Bool, true)
        XCTAssertEqual(req.content.userInfo["base_url"] as? String, "https://monitor.example")
        XCTAssertEqual(req.content.userInfo["topic"] as? String, "monitor")
        XCTAssertEqual(req.content.categoryIdentifier, "")
        XCTAssertFalse(try XCTUnwrap(req.trigger as? UNTimeIntervalNotificationTrigger).repeats)
    }
    func testGermanContentComesFromCompiledCatalog() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "de", withExtension: "lproj"))
        alerts.bundle = try XCTUnwrap(Bundle(url: url))
        configure(3600)
        XCTAssertEqual(try request().content.body, "Seit 1 Stunde keine Nachricht empfangen.")
        for (interval, expected) in zip(QuietTopicAlerts.intervals, ["15 Minuten", "1 Stunde", "6 Stunden", "24 Stunden"]) {
            XCTAssertEqual(QuietTopicAlerts.intervalTitle(interval, bundle: alerts.bundle), expected)
        }
    }
    func testChangeIntervalKeepsReceiptAnchorAndReplacesRequest() throws {
        configure(900)
        let key = QuietTopicAlerts.identifier("first")
        var state = try XCTUnwrap(alerts.defaults.dictionary(forKey: key))
        state["received"] = Date().timeIntervalSince1970 - 300
        alerts.defaults.set(state, forKey: key)
        configure(3600)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(alerts.interval(for: "first"), 3600)
        XCTAssertEqual(try XCTUnwrap(request().trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 3300, accuracy: 2)
        XCTAssertEqual(try request().content.body, "No message received for 1 hour.")
    }
    func testOffCancelsPendingAndDeliveredAndClearsChoiceOnlyForThatTopic() throws {
        configure(900); configure(3600, identity: "second")
        configure(0)
        XCTAssertNil(requests[QuietTopicAlerts.identifier("first")])
        XCTAssertNotNil(requests[QuietTopicAlerts.identifier("second")])
        XCTAssertNil(alerts.defaults.dictionary(forKey: QuietTopicAlerts.identifier("first")))
        XCTAssertTrue(removals.contains(QuietTopicAlerts.identifier("first")))
        alerts.received(identity: "first"); flush()
        XCTAssertEqual(requests.count, 1, "A later message must not revive a disabled choice")
    }
    func testNewMessageRearmsAfterFiringButNoRefreshRepetition() throws {
        configure(900)
        requests.removeAll() // The notification center consumed the one-shot request.
        flush(); XCTAssertTrue(requests.isEmpty)
        alerts.received(identity: "first"); flush()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try XCTUnwrap(request().trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 900, accuracy: 2)
    }
    func testChangingIntervalAfterWindowElapsedDoesNotRepeatUntilNewMessage() throws {
        configure(900)
        let key = QuietTopicAlerts.identifier("first")
        var state = try XCTUnwrap(alerts.defaults.dictionary(forKey: key))
        state["received"] = Date().timeIntervalSince1970 - 1000
        alerts.defaults.set(state, forKey: key)
        requests.removeAll() // The OS has consumed the elapsed one-shot.
        configure(3600)
        XCTAssertTrue(requests.isEmpty, "Changing an expired window must not create another alert before a message")
        configure(21600)
        XCTAssertTrue(requests.isEmpty)
        alerts.received(identity: "first"); flush()
        XCTAssertEqual(try XCTUnwrap(request().trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 21600, accuracy: 2)
    }

    func testFailedSchedulerReportsErrorAndRestoresPriorChoice() throws {
        configure(900)
        alerts.schedule = { _, done in done(URLError(.notConnectedToInternet)) }
        let failed = expectation(description: "error surfaced")
        alerts.configure(identity: "first", baseUrl: "x", topic: "x", title: "x", interval: 3600) { error in
            XCTAssertNotNil(error); failed.fulfill()
        }
        wait(for: [failed], timeout: 5); flush()
        XCTAssertEqual(alerts.interval(for: "first"), 900)
    }
    func testSharedReadersSerializeSettingChangeBehindPendingSchedule() throws {
        var finishFirst: ((Error?) -> Void)?
        let scheduled = expectation(description: "first scheduler holds coordination")
        alerts.schedule = { request, done in self.requests[request.identifier] = request; finishFirst = done; scheduled.fulfill() }
        alerts.configure(identity: "first", baseUrl: "x", topic: "x", title: "x", interval: 900)
        wait(for: [scheduled], timeout: 3)
        let reader = QuietTopicAlerts(defaults: UserDefaults(suiteName: suite)!, directory: root)
        reader.remove = { ids in self.removals += ids }
        reader.configure(identity: "first", baseUrl: "x", topic: "x", title: "x", interval: 0)
        finishFirst?(nil); flush()
        let done = expectation(description: "other process setting applied")
        reader.flush { done.fulfill() }; wait(for: [done], timeout: 5)
        XCTAssertEqual(reader.interval(for: "first"), 0)
        XCTAssertTrue(removals.contains(QuietTopicAlerts.identifier("first")))
    }
    func testExpiryCancellationReleasesLockSynchronouslyBeforeLateCallback() throws {
        let scheduled = expectation(description: "scheduler paused")
        var late: ((Error?) -> Void)?
        alerts.schedule = { _, done in late = done; scheduled.fulfill() }
        alerts.configure(identity: "first", baseUrl: "x", topic: "x", title: "x", interval: 900)
        wait(for: [scheduled], timeout: 3)
        alerts.cancelScheduling()
        let fd = open(root.appendingPathComponent("quietTopics.v1.lock").path, O_RDWR)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        late?(nil); flush()
    }
    func testNSEWaitsForQuietScheduleBeforeNormalContentHandoff() throws {
        let store = Store(inMemory: true); store.quietAlerts = alerts
        let sub = store.saveSubscription(baseUrl: "https://quiet-nse.example", topic: "nse")
        let identity = sub.objectID.uriRepresentation().absoluteString
        configure(900, identity: identity)
        let scheduled = expectation(description: "NSE reached quiet scheduler")
        var resume: ((Error?) -> Void)?
        var handedOff = false
        alerts.schedule = { _, done in resume = done; scheduled.fulfill() }
        let service = NotificationService(); service.makeStore = { store }
        let content = UNMutableNotificationContent()
        content.userInfo = Message(id: "nse-window", time: 1800000000, event: "message", topic: "nse", message: "alive").toUserInfo()
        content.userInfo["base_url"] = sub.baseUrl!
        let delivered = expectation(description: "NSE content after successful schedule")
        service.didReceive(UNNotificationRequest(identifier: "nse-window", content: content, trigger: nil)) { _ in
            handedOff = true; delivered.fulfill()
        }
        wait(for: [scheduled], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(handedOff, "Normal NSE handoff must keep execution until the scheduler callback")
        resume?(nil)
        wait(for: [delivered], timeout: 3)
        withExtendedLifetime(service) {}
    }

    func testNSEExpiryCancelsPendingSchedulerAndHandsOffOnceWithoutWaiting() throws {
        let store = Store(inMemory: true); store.quietAlerts = alerts
        let sub = store.saveSubscription(baseUrl: "https://quiet-expiry.example", topic: "expiry")
        configure(900, identity: sub.objectID.uriRepresentation().absoluteString)
        let scheduled = expectation(description: "pending quiet schedule")
        var resume: ((Error?) -> Void)?
        alerts.schedule = { _, done in resume = done; scheduled.fulfill() }
        let service = NotificationService(); service.makeStore = { store }
        let content = UNMutableNotificationContent()
        content.userInfo = Message(id: "expiry-window", time: 1800000000, event: "message", topic: "expiry", message: "alive").toUserInfo()
        content.userInfo["base_url"] = sub.baseUrl!
        var calls = 0
        service.didReceive(UNNotificationRequest(identifier: "expiry-window", content: content, trigger: nil)) { _ in calls += 1 }
        wait(for: [scheduled], timeout: 3)
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(calls, 1, "Expiry hands off synchronously without a queue wait")
        resume?(nil); flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(service) {}
    }

    func testQueuedOffCannotBeOvertakenByEarlierMessageRestart() throws {
        configure(900)
        let scheduled = expectation(description: "delay a scheduler callback")
        var resume: ((Error?) -> Void)?
        alerts.schedule = { _, done in resume = done; scheduled.fulfill() }
        alerts.received(identity: "first")
        wait(for: [scheduled], timeout: 3)
        alerts.configure(identity: "first", baseUrl: "x", topic: "x", title: "x", interval: 0)
        resume?(nil); flush()
        XCTAssertEqual(alerts.interval(for: "first"), 0)
        XCTAssertNil(requests[QuietTopicAlerts.identifier("first")])
    }

    func testCommittedAppPathsUseSchedulerSeamAndControlsDoNot() throws {
        let store = Store(inMemory: true); store.quietAlerts = alerts
        let sub = store.saveSubscription(baseUrl: "https://private.example", topic: "signed-in")
        let identity = sub.objectID.uriRepresentation().absoluteString
        configure(900, identity: identity)
        let first = try request(identity)
        for event in ["message_clear", "message_delete", "poll_request", "keepalive"] {
            _ = store.ingest(pushedMessage: Message(id: UUID().uuidString, time: 1800000000, event: event, topic: "signed-in"), baseUrl: sub.baseUrl!, topic: sub.topic!)
        }
        let poll = try XCTUnwrap(store.pollRequest(for: sub))
        _ = store.save(notificationsFromMessages: [], polledWith: poll)
        flush(); XCTAssertTrue(try request(identity) === first)
        let message = Message(id: "new", time: 1800000001, event: "message", topic: "signed-in", message: "received")
        _ = store.save(notificationsFromMessages: [message], polledWith: poll)
        flush(); XCTAssertFalse(try request(identity) === first)
        XCTAssertTrue(store.delete(subscription: sub)); flush()
        XCTAssertNil(requests[QuietTopicAlerts.identifier(identity)])
    }
}

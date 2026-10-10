import XCTest
@testable import ntfy

/// On a Mac the system handed banner taps (Approve, a plain click) to the extension process, which
/// dropped them. These pin the relay that carries them to the app, and the guards that keep one tap
/// from running twice or a duplicate's failure from hiding a success.
final class NotificationResponseRelayTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationResponseRelayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func response(_ id: String, action: String = "approve", at date: Date) -> RelayedNotificationResponse {
        RelayedNotificationResponse(notificationId: id, actionIdentifier: action,
                                    userInfo: ["topic": "secret-broker", "id": id], receivedAt: date)
    }

    // MARK: Relay queue

    func testQueuedTapReachesTheAppAcrossInstances() {
        // The extension and the app are different processes, each with its own relay over the App Group.
        let now = Date()
        NotificationResponseRelay(defaults: defaults).enqueue(response("n1", at: now))
        let drained = NotificationResponseRelay(defaults: defaults).drain(now: now.addingTimeInterval(1))
        XCTAssertEqual(drained, [response("n1", at: now)])
    }

    func testDrainEmptiesTheQueue() {
        let relay = NotificationResponseRelay(defaults: defaults)
        let now = Date()
        relay.enqueue(response("n1", at: now))
        XCTAssertEqual(relay.drain(now: now).count, 1)
        XCTAssertEqual(relay.drain(now: now), [])
    }

    func testDrainKeepsOrderAndDropsStaleTaps() {
        let relay = NotificationResponseRelay(defaults: defaults)
        let now = Date()
        relay.enqueue(response("old", at: now.addingTimeInterval(-NotificationResponseRelay.maxAge - 1)))
        relay.enqueue(response("a", at: now.addingTimeInterval(-5)))
        relay.enqueue(response("b", at: now))
        XCTAssertEqual(relay.drain(now: now).map(\.notificationId), ["a", "b"])
    }

    func testQueueIsCapped() {
        let relay = NotificationResponseRelay(defaults: defaults)
        let now = Date()
        for i in 0..<(NotificationResponseRelay.maxQueued + 5) {
            relay.enqueue(response("n\(i)", at: now))
        }
        let drained = relay.drain(now: now)
        XCTAssertEqual(drained.count, NotificationResponseRelay.maxQueued)
        XCTAssertEqual(drained.last?.notificationId, "n\(NotificationResponseRelay.maxQueued + 4)")
    }

    func testStringValuesKeepsTheMessageFieldsAndDropsTheRest() {
        let userInfo: [AnyHashable: Any] = [
            "id": "abc", "topic": "t", "actions": "[]", "aps": ["alert": "x"], "priority": 5, 1: "int key"
        ]
        XCTAssertEqual(NotificationResponseRelay.stringValues(userInfo), ["id": "abc", "topic": "t", "actions": "[]"])
    }

    func testRelayedUserInfoStillDecodesToAMessage() throws {
        let userInfo: [AnyHashable: Any] = [
            "id": "abc", "time": "1760040000", "event": "message", "topic": "secret-broker",
            "message": "Approve?", "aps": ["alert": "x"]
        ]
        let message = try XCTUnwrap(Message.from(userInfo: NotificationResponseRelay.stringValues(userInfo)))
        XCTAssertEqual(message.id, "abc")
        XCTAssertEqual(message.topic, "secret-broker")
    }

    // MARK: Each tap once

    func testDeduperHandlesEachTapOnce() {
        var deduper = NotificationResponseDeduper()
        let now = Date()
        XCTAssertTrue(deduper.shouldHandle(notificationId: "n1", actionIdentifier: "approve", now: now))
        XCTAssertFalse(deduper.shouldHandle(notificationId: "n1", actionIdentifier: "approve", now: now.addingTimeInterval(3)))
        XCTAssertTrue(deduper.shouldHandle(notificationId: "n1", actionIdentifier: "deny", now: now))
        XCTAssertTrue(deduper.shouldHandle(notificationId: "n2", actionIdentifier: "approve", now: now))
        XCTAssertTrue(deduper.shouldHandle(notificationId: "n1", actionIdentifier: "approve",
                                           now: now.addingTimeInterval(NotificationResponseDeduper.window + 1)))
    }

    // MARK: ActionExecutor: repeat taps, retries, failure after success

    func testRepeatTapWithinTheWindowDoesNotRunAgain() {
        // 2026-10-09 16:57:18: a double click sent a second POST 180 ms after the first.
        var taps: [String: Date] = [:]
        let now = Date()
        XCTAssertTrue(ActionExecutor.shouldRun(actionId: "a1", at: now, lastTaps: &taps))
        XCTAssertFalse(ActionExecutor.shouldRun(actionId: "a1", at: now.addingTimeInterval(0.18), lastTaps: &taps))
        XCTAssertTrue(ActionExecutor.shouldRun(actionId: "a2", at: now.addingTimeInterval(0.18), lastTaps: &taps))
        XCTAssertTrue(ActionExecutor.shouldRun(actionId: "a1", at: now.addingTimeInterval(ActionExecutor.repeatTapWindow + 0.1),
                                               lastTaps: &taps))
    }

    func testFailureAfterSuccessIsNotReported() {
        // The duplicate's "⚠️ Approve failed — HTTP 429" replaced the first POST's ✅.
        var successes: [String: Date] = [:]
        let now = Date()
        XCTAssertTrue(ActionExecutor.shouldReport(actionId: "a1", success: true, at: now, lastSuccesses: &successes))
        XCTAssertFalse(ActionExecutor.shouldReport(actionId: "a1", success: false, at: now.addingTimeInterval(9), lastSuccesses: &successes))
        XCTAssertTrue(ActionExecutor.shouldReport(actionId: "a2", success: false, at: now.addingTimeInterval(9), lastSuccesses: &successes))
        XCTAssertTrue(ActionExecutor.shouldReport(actionId: "a1", success: false,
                                                  at: now.addingTimeInterval(ActionExecutor.successMemory + 1), lastSuccesses: &successes))
    }

    private func http(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/secret-broker-approve")!,
                        statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testRateLimitedAndUnavailableAreRetriedWithBackoff() {
        XCTAssertEqual(ActionExecutor.retryDelay(response: http(429), error: nil, attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: http(503), error: nil, attempt: 2), 2)
        XCTAssertNil(ActionExecutor.retryDelay(response: http(429), error: nil, attempt: ActionExecutor.maxAttempts))
    }

    func testRetryAfterIsHonoredAndCapped() {
        XCTAssertEqual(ActionExecutor.retryDelay(response: http(429, headers: ["Retry-After": "3"]), error: nil, attempt: 1), 3)
        XCTAssertEqual(ActionExecutor.retryDelay(response: http(429, headers: ["Retry-After": "600"]), error: nil, attempt: 1),
                       ActionExecutor.maxRetryDelay)
    }

    func testOtherOutcomesAreNotRetried() {
        XCTAssertNil(ActionExecutor.retryDelay(response: http(200), error: nil, attempt: 1))
        XCTAssertNil(ActionExecutor.retryDelay(response: http(401), error: nil, attempt: 1))
        XCTAssertNil(ActionExecutor.retryDelay(response: http(500), error: nil, attempt: 1))
        // A timeout may have delivered the request; repeating it could approve twice.
        XCTAssertNil(ActionExecutor.retryDelay(response: nil, error: URLError(.timedOut), attempt: 1))
        XCTAssertNil(ActionExecutor.retryDelay(response: nil, error: URLError(.networkConnectionLost), attempt: 1))
    }

    func testUnsentRequestsAreRetried() {
        XCTAssertEqual(ActionExecutor.retryDelay(response: nil, error: URLError(.notConnectedToInternet), attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: nil, error: URLError(.cannotConnectToHost), attempt: 2), 2)
    }

    // MARK: Extension lifetime (Mac)

    /// Scheduled exits run only when the test fires them, so it controls the timing.
    private final class LifetimeHarness {
        var pending: [(delay: TimeInterval, work: () -> Void)] = []
        var exits = 0
        lazy var lifetime = NotificationExtensionLifetime(
            enabled: enabled,
            schedule: { [unowned self] delay, work in self.pending.append((delay, work)) },
            exitProcess: { [unowned self] in self.exits += 1 }
        )
        private let enabled: Bool
        init(enabled: Bool = true) { self.enabled = enabled }
        func firePending() {
            let due = pending
            pending = []
            due.forEach { $0.work() }
        }
    }

    func testExtensionExitsShortlyAfterItsLastDelivery() {
        // Build 27 on a Mac: the suspended extension held an Approve tap until the next push.
        let harness = LifetimeHarness()
        harness.lifetime.requestStarted()
        XCTAssertTrue(harness.pending.isEmpty)
        harness.lifetime.requestFinished()
        XCTAssertEqual(harness.pending.map(\.delay), [NotificationExtensionLifetime.exitDelay])
        XCTAssertEqual(harness.exits, 0)
        harness.firePending()
        XCTAssertEqual(harness.exits, 1)
    }

    func testExtensionStaysWhileAnotherRequestIsInFlight() {
        let harness = LifetimeHarness()
        harness.lifetime.requestStarted()
        harness.lifetime.requestStarted()
        harness.lifetime.requestFinished()
        harness.firePending()
        XCTAssertEqual(harness.exits, 0)
        harness.lifetime.requestFinished()
        harness.firePending()
        XCTAssertEqual(harness.exits, 1)
    }

    func testANewRequestCancelsAScheduledExit() {
        let harness = LifetimeHarness()
        harness.lifetime.requestStarted()
        harness.lifetime.requestFinished()
        harness.lifetime.requestStarted()
        harness.lifetime.requestFinished()
        XCTAssertEqual(harness.pending.count, 2)
        // The first delivery's timer fires before the second's delay is up: its exit was cancelled,
        // so the second banner's taps still get their full window to land in the relay.
        harness.pending.removeFirst().work()
        XCTAssertEqual(harness.exits, 0)
        harness.firePending()
        XCTAssertEqual(harness.exits, 1)
    }

    func testExtensionIsLeftToTheSystemOffTheMac() {
        let harness = LifetimeHarness(enabled: false)
        harness.lifetime.requestStarted()
        harness.lifetime.requestFinished()
        harness.firePending()
        XCTAssertTrue(harness.pending.isEmpty)
        XCTAssertEqual(harness.exits, 0)
    }
}

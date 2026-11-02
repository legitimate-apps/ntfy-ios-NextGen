import XCTest
import UserNotifications
@testable import ntfy

final class QuietHoursStorageTests: XCTestCase {
    func testAtomicPreferencesRoundTripAndFreshReader() {
        let suite = "QuietHours.Storage." + UUID().uuidString
        let first = UserDefaults(suiteName: suite)!, second = UserDefaults(suiteName: suite)!
        defer { first.removePersistentDomain(forName: suite) }
        XCTAssertFalse(QuietHours.load(from: first).enabled)
        var value = QuietHours(); value.enabled = true; value.start = 123; value.end = 456
        value.days = [2,4]; value.allowUrgent = false; value.exceptions = ["https://one.example/topic"]
        value.save(to: first)
        XCTAssertEqual(QuietHours.load(from: second), value)
        value.enabled = false; value.save(to: first)
        XCTAssertFalse(QuietHours.load(from: second).enabled)
    }
    func testInvalidTimeValuesFailOpenAndZoneChangesUseCurrentWallClock() {
        var value = QuietHours(); value.enabled = true; value.start = -1
        XCTAssertFalse(value.contains(Date()))
        value.start = 0; value.end = 1440
        XCTAssertFalse(value.contains(Date()))
        value.start = 9 * 60; value.end = 10 * 60
        let instant = ISO8601DateFormatter().date(from: "2026-11-02T14:30:00Z")!
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        var la = ny; la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertTrue(value.contains(instant, calendar: ny)); XCTAssertFalse(value.contains(instant, calendar: la))
    }
    func testCriticalAndNamedSoundsAreSilencedAfterMappingAndMuteStillWins() throws {
        let defaults = QuietHours.defaults; let previous = defaults.object(forKey: QuietHours.key)
        defer { defaults.set(previous, forKey: QuietHours.key); defaults.synchronize() }
        var policy = QuietHours(); policy.enabled = true; policy.start = 0; policy.end = 0; policy.allowUrgent = false; policy.save()
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://quiet-policy.example", topic: UUID().uuidString)
        defer { _ = store.delete(subscription: sub) }
        let message = Message(id: UUID().uuidString, time: 1, event: "message", topic: sub.topic!, priority: 5)
        let content = UNMutableNotificationContent(); content.userInfo = message.toUserInfo(); content.userInfo["base_url"] = sub.baseUrl!
        content.configureInterruption(message: message, soundName: "custom.wav", criticalEnabled: true, criticalAuthorized: true)
        XCTAssertEqual(content.interruptionLevel, .critical); XCTAssertNotNil(content.sound)
        content.applyTopicMute()
        XCTAssertEqual(content.interruptionLevel, .passive); XCTAssertNil(content.sound)
        policy.allowUrgent = true; policy.save()
        content.configureInterruption(message: message, soundName: "custom.wav", criticalEnabled: true, criticalAuthorized: true)
        content.applyTopicMute()
        XCTAssertEqual(content.interruptionLevel, .critical); XCTAssertNotNil(content.sound)
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        content.applyTopicMute()
        XCTAssertEqual(content.interruptionLevel, .passive); XCTAssertNil(content.sound)
    }
    func testHashedPollResolvesAllowedTopicOnItsOwnServer() {
        let defaults = QuietHours.defaults; let previous = defaults.object(forKey: QuietHours.key)
        defer { defaults.set(previous, forKey: QuietHours.key); defaults.synchronize() }
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://quiet-hash.example", topic: UUID().uuidString)
        defer { _ = store.delete(subscription: sub) }
        var policy = QuietHours(); policy.enabled = true; policy.start = 0; policy.end = 0
        policy.exceptions = [topicUrl(baseUrl: sub.baseUrl!, topic: sub.topic!)]; policy.save()
        let info: [AnyHashable:Any] = ["topic":sub.urlHash(), "event":"poll_request", "base_url":sub.baseUrl!]
        XCTAssertFalse(store.isNotificationMuted(userInfo: info))
        policy.exceptions = []; policy.save()
        XCTAssertTrue(store.isNotificationMuted(userInfo: info))
    }
    func testRefreshDoesNotRearmElapsedAbsenceWindow() {
        let suite = "QuietHours.Refresh." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let alerts = QuietTopicAlerts(defaults: defaults, directory: nil)
        let key = QuietTopicAlerts.identifier("elapsed")
        defaults.set(["interval":900.0,"received":Date().timeIntervalSince1970 - 1000,
                      "baseUrl":"https://quiet.example","topic":"elapsed"], forKey:key)
        var scheduled = 0
        alerts.schedule = { _, done in scheduled += 1; done(nil) }
        alerts.refreshQuietHours()
        let done = expectation(description: "refresh serialized"); alerts.flush { done.fulfill() }
        wait(for:[done],timeout:5)
        XCTAssertEqual(scheduled, 0)
    }
    func testRefreshingPendingAbsenceAlertPreservesReceiptAnchorAndRestoresSound() {
        let shared = QuietHours.defaults; let previous = shared.object(forKey: QuietHours.key)
        defer { shared.set(previous, forKey: QuietHours.key); shared.synchronize() }
        var policy = QuietHours(); policy.enabled = true; policy.start = 0; policy.end = 0; policy.save()
        let suite = "QuietHours.RefreshPending." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let alerts = QuietTopicAlerts(defaults: defaults, directory: nil)
        let key = QuietTopicAlerts.identifier("pending")
        let received = Date().timeIntervalSince1970 - 100
        defaults.set(["interval":900.0,"received":received,"baseUrl":"https://quiet.example","topic":"pending"], forKey:key)
        var outputs: [UNNotificationRequest] = []
        alerts.schedule = { request, done in outputs.append(request); done(nil) }
        func flush() {
            let done = expectation(description: "pending refresh"); alerts.flush { done.fulfill() }; wait(for:[done],timeout:5)
        }
        alerts.refreshQuietHours(); flush()
        XCTAssertEqual(outputs.count, 1); XCTAssertNil(outputs.last?.content.sound)
        XCTAssertEqual(outputs.last?.content.interruptionLevel, .passive)
        policy.enabled = false; policy.save()
        alerts.refreshQuietHours(); flush()
        XCTAssertEqual(outputs.count, 2); XCTAssertNotNil(outputs.last?.content.sound)
        XCTAssertEqual(outputs.last?.content.interruptionLevel, .active)
        XCTAssertEqual(defaults.dictionary(forKey:key)?["received"] as? Double, received)
        XCTAssertEqual((outputs.last?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval ?? 0, 800, accuracy:2)
    }
}

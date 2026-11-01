import XCTest
import UserNotifications
@testable import ntfy

/// Uses existing main APIs and the shared preferences format, so RED tests run on exact main.
final class QuietHoursTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: Config.appGroupId)!
    private let key = "quietHours.v1"
    private var previous: Any?
    private var subscriptions: [Subscription] = []
    private let center = UNUserNotificationCenter.current()
    override func setUp() { previous = defaults.object(forKey: key) }
    override func tearDown() {
        defaults.set(previous, forKey: key); defaults.synchronize()
        subscriptions.forEach { _ = Store.shared.delete(subscription: $0) }
    }
    private func configure(start: Int = 0, end: Int = 0, days: [Int] = Array(1...7), urgent: Bool = true,
                           exceptions: [String] = [], enabled: Bool = true) {
        defaults.set(["enabled": enabled, "start": start, "end": end, "days": days,
                      "allowUrgent": urgent, "exceptions": exceptions], forKey: key)
        defaults.synchronize()
    }
    private func info(priority: Int = 3, topic: String = "schedule") -> [AnyHashable: Any] {
        var info = Message(id: UUID().uuidString, time: 1, event: "message", topic: topic,
                           message: "Quiet hours history", priority: Int16(priority)).toUserInfo()
        info["base_url"] = "https://quiet-hours.example"
        return info
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    func testSameDayStartIncludedEndExcludedAndDisabled() {
        configure(start: 9 * 60, end: 17 * 60)
        for (hour, expected) in [(8,false),(9,true),(16,true),(17,false),(23,false)] {
            XCTAssertEqual(Store.shared.isNotificationMuted(userInfo: info(), now: date(2,hour)), expected, "hour=\(hour)")
        }
        configure(enabled: false)
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: date(2,12)))
    }
    func testMidnightUsesStartingWeekdayAndWeekWrap() {
        configure(start: 22 * 60, end: 7 * 60, days: [2]) // Monday
        for (day,hour,expected) in [(2,21,false),(2,22,true),(3,0,true),(3,6,true),(3,7,false),(3,22,false),(2,6,false)] {
            XCTAssertEqual(Store.shared.isNotificationMuted(userInfo: info(), now: date(day,hour)), expected, "day=\(day), hour=\(hour)")
        }
        configure(start: 22 * 60, end: 7 * 60, days: [7]) // Saturday into Sunday
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(), now: date(1,6)))
    }
    func testEqualTimesMeanWholeSelectedDayAndNoDaysMeansOff() {
        configure(start: 600, end: 600, days: [2])
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(), now: date(2,0)))
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(), now: date(2,23)))
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: date(3,12)))
        configure(days: [])
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: date(2,12)))
    }
    func testDSTFallBackBothRepeatedHoursAndSpringForwardUseWallClock() {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = previousZone }
        let iso = ISO8601DateFormatter()
        configure(start: 60, end: 120, days: [1])
        for timestamp in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(), now: iso.date(from: timestamp)!))
        }
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: iso.date(from: "2026-11-01T07:00:00Z")!))
        configure(start: 150, end: 240, days: [1])
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: iso.date(from: "2026-03-08T06:59:00Z")!))
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(), now: iso.date(from: "2026-03-08T07:00:00Z")!))
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(), now: iso.date(from: "2026-03-08T08:00:00Z")!))
    }
    func testPriorityFiveOptOutExceptionsAndMuteWins() throws {
        configure()
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(priority: 4)))
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info(priority: 5)))
        configure(urgent: false)
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(priority: 5)))
        configure(exceptions: ["https://quiet-hours.example/schedule"])
        XCTAssertFalse(Store.shared.isNotificationMuted(userInfo: info()))
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(topic: "other")))
        let sub = subscription()
        try Store.shared.setTopicMute(until: .distantFuture, subscription: sub)
        XCTAssertTrue(Store.shared.isNotificationMuted(userInfo: info(priority: 5)))
    }
    private func subscription() -> Subscription {
        let sub = Store.shared.saveSubscription(baseUrl: "https://quiet-hours.example", topic: "schedule")
        subscriptions.append(sub); return sub
    }
    func testActualNSEEntrySilencesCriticalContentAndKeepsHistory() {
        configure(urgent: false)
        let sub = subscription()
        for priority in [3,5] {
            let content = UNMutableNotificationContent(); content.userInfo = info(priority: priority)
            content.sound = .defaultCritical; content.interruptionLevel = .critical
            let done = expectation(description: "NSE final content")
            let service = NotificationService()
            service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { output in
                XCTAssertNil(output.sound)
                XCTAssertEqual(output.interruptionLevel, .passive)
                XCTAssertEqual(output.relevanceScore, 0)
                XCTAssertEqual(output.body, "Quiet hours history")
                done.fulfill()
            }
            wait(for: [done], timeout: 8)
        }
        XCTAssertEqual(sub.notificationCount(), 2)
        XCTAssertEqual(sub.unreadCount(), 2)
    }
    func testScheduledAbsenceAlertUsesFutureQuietWindow() {
        configure(urgent: false)
        let suite = "QuietHours.Absence." + UUID().uuidString
        let local = UserDefaults(suiteName: suite)!
        defer { local.removePersistentDomain(forName: suite) }
        let alerts = QuietTopicAlerts(defaults: local, directory: nil)
        let scheduled = expectation(description: "absence alert scheduled")
        alerts.schedule = { request, done in
            XCTAssertNil(request.content.sound)
            XCTAssertEqual(request.content.interruptionLevel, .passive)
            XCTAssertEqual(request.content.body, "No message received for 15 minutes.")
            scheduled.fulfill(); done(nil)
        }
        alerts.configure(identity: "quiet-hours-absence", baseUrl: "https://quiet-hours.example",
                         topic: "monitor", title: "Monitor", interval: 900)
        wait(for: [scheduled], timeout: 5)
        let flushed = expectation(description: "scheduler finished")
        alerts.flush { flushed.fulfill() }; wait(for: [flushed], timeout: 5)
    }
    func testNSEUrgentExceptionAndMalformedFallback() {
        configure()
        _ = subscription()
        for malformed in [false,true] {
            let content = UNMutableNotificationContent(); content.userInfo = malformed ? ["topic":"schedule"] : info(priority: 5)
            content.body = "Fallback"; content.sound = .default; content.interruptionLevel = .active
            let done = expectation(description: "NSE urgent/fallback")
            NotificationService().didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { output in
                XCTAssertEqual(output.sound == nil, malformed)
                XCTAssertEqual(output.interruptionLevel == .passive, malformed)
                done.fulfill()
            }
            wait(for: [done], timeout: 8)
        }
    }
    func testNSEExpiryDoesNotWaitForDatabaseAndKeepsQuietPolicy() {
        configure(urgent: false)
        let sub = Store.shared.saveSubscription(baseUrl: "http://127.0.0.1:1", topic: "expiry-quiet")
        subscriptions.append(sub)
        let content = UNMutableNotificationContent(); content.sound = .defaultCritical; content.interruptionLevel = .critical
        content.userInfo = ["id":"quiet-expiry", "time":"1", "event":"poll_request", "topic":sub.urlHash(), "base_url":sub.baseUrl!]
        let done = expectation(description: "synchronous expiry"); done.assertForOverFulfill = true
        let service = NotificationService()
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { output in
            XCTAssertNil(output.sound); XCTAssertEqual(output.interruptionLevel, .passive); done.fulfill()
        }
        service.serviceExtensionTimeWillExpire()
        wait(for: [done], timeout: 2)
    }
    func testAppScheduledContentAndForegroundDelegateKeepHistoryWithoutBanner() throws {
        configure(urgent: false)
        let sub = subscription()
        let msg = Message(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970), event: "message",
                          topic: sub.topic!, message: "App scheduled quiet history", priority: 5)
        let app = AppDelegate()
        let scheduled = expectation(description: "real app scheduling policy")
        app.notificationScheduler = { request, done in
            XCTAssertNil(request.content.sound); XCTAssertEqual(request.content.interruptionLevel, .passive)
            scheduled.fulfill(); done(nil)
        }
        app.showNotification(baseUrl: sub.baseUrl!, msg)
        wait(for: [scheduled], timeout: 8)
        let auth = expectation(description: "permission"); var allowed = false
        center.getNotificationSettings { settings in
            allowed = [.authorized,.provisional].contains(settings.authorizationStatus); auth.fulfill()
        }
        wait(for: [auth], timeout: 5)
        guard allowed else { throw XCTSkip("Grant notifications on owned simulator for OS delegate coverage") }
        let capture = QuietHoursCapture(); let previousDelegate = center.delegate; center.delegate = capture
        defer { center.delegate = previousDelegate }
        let foreground = expectation(description: "real foreground notification")
        let id = UUID().uuidString
        defer { center.removeDeliveredNotifications(withIdentifiers: [id]) }
        capture.receive = { notification in
            app.userNotificationCenter(self.center, willPresent: notification) { options in
                XCTAssertEqual(options, [.list]); foreground.fulfill()
            }
        }
        let content = UNMutableNotificationContent(); content.userInfo = info(priority: 5)
        content.body = "Raw foreground history"; content.sound = .defaultCritical; content.interruptionLevel = .critical
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { XCTAssertNil($0) }
        wait(for: [foreground], timeout: 8)
        XCTAssertEqual(sub.notificationCount(), 1)
        XCTAssertEqual(sub.unreadCount(), 1)
    }
}
private final class QuietHoursCapture: NSObject, UNUserNotificationCenterDelegate {
    var receive: ((UNNotification) -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        receive?(notification); completionHandler([.list])
    }
}

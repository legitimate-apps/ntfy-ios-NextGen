import XCTest
import CoreFoundation

final class NavigationPilotUITests: XCTestCase {
    lazy var app = XCUIApplication(bundleIdentifier: setting("NTFYTestAppID"))
    func setting(_ key: String) -> String {
        Bundle(for: Self.self).object(forInfoDictionaryKey: key) as! String
    }
    let target = "zz-nav-118-regression"
    let newTopic = "zz-nav-118-new"
    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.18.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = setting("NTFYTestHarness")
    }
    func test00ResolveLaunchAlert() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5))
    }
    func launchList() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts[target].exists)
        // 60 earlier rows make the target absent from the rendered viewport.
        XCTAssertFalse(app.staticTexts[target].firstMatch.exists && app.staticTexts[target].firstMatch.isHittable, "fixture target must start off screen")
    }
    func assertTarget() {
        XCTAssertTrue(app.navigationBars.staticTexts[target].waitForExistence(timeout: 8), "off-screen target must open without scrolling")
        XCTAssertTrue(app.navigationBars.buttons["Subscribed topics"].exists)
        XCTAssertTrue(app.buttons["More"].exists)
    }
    func testURLNewCold() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["Topic name, e.g. alerts-k7m2-x9qp"].value as? String, newTopic)
        XCTAssertEqual(app.textFields["Service URL, e.g. https://ntfy.home.io"].value as? String, "https://ntfy-me.com")
    }
    func testNotificationWarmOffscreen() {
        launchList()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
    }
    func testNotificationColdOffscreen() {
        app.terminate()
        app.launchEnvironment["NTFY_NAV_COLD_RESPONSE"] = "1"
        app.launch()
        assertTarget()
    }
    func testURLFollowedColdOffscreen() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testURLNewWarmRepeatedAndSheetReplacement() {
        launchList()
        for _ in 0..<2 {
            app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
            XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Topic name, e.g. alerts-k7m2-x9qp"].value as? String, newTopic)
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5))
            // One tap leaves one sheet, with no second presentation after Cancel.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(app.navigationBars["Add subscription"].exists)
        }
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testNotificationFromSettingsAndSheet() {
        launchList()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
        app.navigationBars.buttons["Subscribed topics"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
    }
    func testNotificationWhileAnotherTopicIsOpen() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
    }
    func testWhatsNewIsReplacedByURL() {
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["What's new"].waitForExistence(timeout: 8))
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Topic name, e.g. alerts-k7m2-x9qp"].value as? String, newTopic)
    }
    func testReservedInvalidAndOtherHostDoNothing() {
        launchList()
        for url in ["https://ntfy-me.com/docs", "https://ntfy-me.com/a/b", "https://ntfy.sh/alerts"] {
            app.open(URL(string: url)!)
            XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["Add subscription"].exists)
        }
    }
    func testBackAndScrollingDoNotReplaySelectionAndRowsStillOpen() {
        launchList()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
        app.navigationBars.buttons["Subscribed topics"].tap()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5))
        for _ in 0..<20 {
            if app.staticTexts[target].firstMatch.exists && app.staticTexts[target].firstMatch.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts[target].firstMatch.isHittable)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.navigationBars["Subscribed topics"].exists, "scrolling must not replay the consumed notification")
        app.staticTexts[target].firstMatch.tap()
        assertTarget()
    }
    func testURLFollowedOffscreen() {
        launchList()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testYSubscribeRequiresTapThenOpensTopic() {
        launchList()
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Topic name, e.g. alerts-k7m2-x9qp"].value as? String, newTopic)
        app.buttons["Subscribe"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts[newTopic].waitForExistence(timeout: 15))
        confirmUnsubscribe()
    }
    func confirmUnsubscribe() {
        app.buttons["More"].tap()
        app.buttons["Unsubscribe"].tap()
        XCTAssertTrue(app.alerts["Unsubscribe"].waitForExistence(timeout: 3))
        app.alerts["Unsubscribe"].buttons["Unsubscribe"].tap()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 5), "unsubscribing must dismiss its message list")
    }
    func testZUnsubscribeManuallyOpenedTopic() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        confirmUnsubscribe()
        XCTAssertFalse(app.staticTexts["aaa-nav-000"].exists)
    }
    func testZZUnsubscribeExternallyOpenedTopic() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
        confirmUnsubscribe()
        XCTAssertFalse(app.staticTexts[target].exists)
    }

}

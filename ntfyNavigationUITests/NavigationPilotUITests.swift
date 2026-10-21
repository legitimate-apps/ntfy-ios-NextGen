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
        XCTAssertTrue(app.buttons["Topic actions"].exists)
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
        app.buttons["Add subscription"].tap()
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
        app.buttons["Add subscription"].tap()
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
        app.buttons["Topic actions"].tap()
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

    func muteScreenshot(_ name: String) {
        captureAX(name)
    }
    func revealMuteChoice(_ title: String, scrollingUp: Bool = true) -> XCUIElement {
        let button = app.buttons[title]
        for _ in 0..<4 {
            if button.exists && button.isHittable { return button }
            if scrollingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(button.exists && button.isHittable, "Mute choice must be reachable: \(title)")
        return button
    }
    func testTopicMuteMenusPersistenceSwipeAndResume() {
        launchList()
        let row = app.staticTexts["aaa-nav-000"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        muteScreenshot("mute-topic-context-menu")
        app.buttons["Mute topic"].tap()
        XCTAssertTrue(app.navigationBars["Mute topic"].waitForExistence(timeout: 3))
        let largeText = app.buttons["30 minutes"].frame.height > 60
        muteScreenshot("mute-duration-picker")
        for choice in ["30 minutes", "1 hour", "2 hours", "8 hours", "Until tomorrow, 8:30 AM", "Until resumed"] {
            _ = revealMuteChoice(choice)
        }
        if largeText {
            app.swipeUp()
            muteScreenshot("mute-duration-picker-scrolled")
        }
        revealMuteChoice("30 minutes", scrollingUp: false).tap()
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications muted until ")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        muteScreenshot("muted-topic-list")
        app.terminate(); app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "mute must survive a restart")
        row.swipeLeft()
        muteScreenshot("mute-swipe-actions")
        app.buttons["Mute settings"].tap()
        app.buttons["Unmute"].tap()
        XCTAssertFalse(status.exists)
        row.tap()
        app.navigationBars.buttons["Topic actions"].tap()
        muteScreenshot("mute-topic-menu")
        app.buttons["Mute topic"].tap()
        revealMuteChoice("Until resumed").tap()
        XCTAssertTrue(app.staticTexts["Notifications muted until resumed"].waitForExistence(timeout: 3))
        muteScreenshot("muted-topic-history")
        app.navigationBars.buttons["Topic actions"].tap()
        app.buttons["Mute settings"].tap()
        app.buttons["Unmute"].tap()
        XCTAssertFalse(app.staticTexts["Notifications muted until resumed"].exists)
    }

    func captureAX(_ name: String) {
        print("AXTREE-BEGIN " + name + "\n" + app.debugDescription + "\nAXTREE-END " + name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + ".txt"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
    func tapEither(_ label: String, _ old: String) {
        let named = app.buttons[label].firstMatch
        if named.exists { named.tap() }
        else if label == "Message actions" { app.buttons.matching(identifier: old).element(boundBy: 1).tap() }
        else if label == "Attachment actions" { app.buttons.matching(identifier: old).element(boundBy: 2).tap() }
        else { app.buttons[old].firstMatch.tap() }
    }
    func testAccessibilityControlNames() {
        continueAfterFailure = true
        app.launch()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 8))
        captureAX("regression-list")
        XCTAssertTrue(app.buttons["Add subscription"].exists, "The primary action needs its spoken name")
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        captureAX("regression-topic")
        XCTAssertTrue(app.buttons["Topic actions"].exists)
        XCTAssertTrue(app.buttons["Message actions"].firstMatch.exists)
        XCTAssertTrue(app.images["High priority"].exists)
        XCTAssertFalse(app.images["priority-4"].exists)
        XCTAssertTrue(app.buttons["Attachment actions"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Open image"].exists)
    }
    // Run separately with --seed --empty-fixture, after the navigation suite.
    func testAccessibilityEmptyList() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 8))
        guard !app.staticTexts["aaa-nav-000"].exists else { throw XCTSkip("Run with --seed --empty-fixture") }
        captureAX("empty-topic-list")
        XCTAssertTrue(app.staticTexts["It looks like you don't have any subscriptions yet"].exists)
    }
    func testCaptureSavedUserRow() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let user = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        for _ in 0..<16 { if user.exists && user.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(user.isHittable)
        captureAX("saved-user-row")
        user.tap()
        captureAX("edit-user")
        app.buttons["Cancel"].tap()
    }
    func testCaptureAccessibilityScreens() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Subscribed topics"].waitForExistence(timeout: 8))
        captureAX("topic-list")
        tapEither("Add subscription", "Add")
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        captureAX("add-subscription")
        app.buttons["Cancel"].tap()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        captureAX("topic-and-attachments")
        tapEither("Message actions", "More")
        captureAX("message-menu")
        app.tapCoordinateOutsideMenu()
        tapEither("Attachment actions", "More")
        captureAX("attachment-menu")
        app.tapCoordinateOutsideMenu()
        if app.buttons["Open image"].exists { app.buttons["Open image"].tap() }
        else { app.images.matching(NSPredicate(format: "label == ''")).firstMatch.tap() }
        captureAX("fullscreen-image")
        app.buttons["Close"].tap()
        tapEither("Topic actions", "More")
        captureAX("topic-menu")
        app.tapCoordinateOutsideMenu()
        app.navigationBars.buttons["Subscribed topics"].tap()
        app.buttons["Settings"].tap()
        captureAX("settings-top")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default server'")).firstMatch.tap()
        captureAX("default-server")
        let field = app.textFields.firstMatch
        field.tap(); field.typeText("http://localhost:8080")
        captureAX("default-server-clear")
        app.buttons["Cancel"].tap()
        for _ in 0..<16 { if app.buttons["Add user"].isHittable { break }; app.swipeUp() }
        captureAX("settings-users")
        app.buttons["Add user"].tap()
        captureAX("user-editor")
        XCTAssertTrue(app.buttons["Username and password"].isSelected)
        XCTAssertEqual(app.textFields["server-username"].label, "Username")
        XCTAssertEqual(app.secureTextFields["server-password"].label, "Password")
        app.buttons["Access token"].tap()
        XCTAssertTrue(app.buttons["Access token"].isSelected)
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Access token")
        XCTAssertFalse(app.textFields["server-username"].exists)
        captureAX("user-editor-access-token")
        app.buttons["Cancel"].tap()
        for _ in 0..<16 { if app.buttons["Custom HTTP headers"].isHittable { break }; app.swipeUp() }
        app.buttons["Custom HTTP headers"].tap()
        captureAX("server-headers")
        app.navigationBars.buttons["Settings"].tap()
        app.terminate()
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["What's new"].waitForExistence(timeout: 8))
        captureAX("whats-new")
    }

    func testTopicQRControlsHaveSpokenNames() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        app.buttons["Topic actions"].tap()
        app.buttons["Show QR code"].tap()
        XCTAssertTrue(app.navigationBars["QR code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["QR code for 127.0.0.1:1/aaa-nav-000"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)
        captureAX("topic-qr-code")
        app.buttons["Done"].tap()
        app.navigationBars.buttons["Subscribed topics"].tap()
        app.buttons["Add subscription"].tap()
        let scan = app.buttons["Scan QR code"]
        for _ in 0..<6 { if scan.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(scan.isHittable)
        captureAX("add-subscription-scan-entry")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan QR code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This device has no camera. Type the topic and server in instead."].exists)
        XCTAssertFalse(app.images["camera"].exists)
        let cancelScan = app.navigationBars["Scan QR code"].buttons["Cancel"]
        XCTAssertTrue(cancelScan.exists)
        captureAX("topic-qr-scanner")
        cancelScan.tap()
        XCTAssertTrue(app.navigationBars["Add subscription"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

}

private extension XCUIApplication {
    func tapCoordinateOutsideMenu() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.50)).tap()
    }
}

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

/// These assertions launch the actual app in German, with server content kept verbatim.
/// Run separately from the unchanged English navigation suite using run.py --german.
final class GermanLocalizationUITests: XCTestCase {
    lazy var app = XCUIApplication(bundleIdentifier: Bundle(for: Self.self).object(forInfoDictionaryKey: "NTFYTestAppID") as! String)
    let firstTopic = "aaa-nav-000"
    let language = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = language + ["-ntfyDebugLastSeenVersion", "1.18.0", "-notificationPermissionPrimerOffered", "YES"]
    }
    func capture(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "de-" + name + ".txt"; tree.lifetime = .keepAlways; add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "de-" + name; shot.lifetime = .keepAlways; add(shot)
    }
    func reveal(_ element: XCUIElement, up: Bool = true, attempts: Int = 40) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            // Small steps keep short controls from being skipped on SE at accessibility sizes.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.70 : 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.45 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "Expected a reachable German control: \(element)")
    }
    func launch() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] {
            if springboard.buttons[label].waitForExistence(timeout: 1) { springboard.buttons[label].tap() }
        }
        capture("launch")
        XCTAssertTrue(app.navigationBars["Abonnierte Themen"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Add subscription"].exists)
        XCTAssertTrue(app.buttons["Neues Abo"].exists)
    }
    func testGermanMainScreens() {
        launch()
        capture("topic-list")
        app.staticTexts[firstTopic].firstMatch.tap()
        XCTAssertTrue(app.buttons["Themenaktionen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Nachrichtenaktionen"].firstMatch.exists)
        XCTAssertTrue(app.images["Hohe Priorität"].exists)
        XCTAssertTrue(app.buttons["Anhangaktionen"].firstMatch.exists)
        capture("topic-attachments")
        app.buttons["Nachrichtenaktionen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Nachricht kopieren"].exists)
        capture("message-menu")
        app.tapCoordinateOutsideMenu()
        app.buttons["Anhangaktionen"].firstMatch.tap()
        capture("attachment-menu")
        app.tapCoordinateOutsideMenu()
        app.buttons["Themenaktionen"].tap()
        XCTAssertTrue(app.buttons["Thema stummschalten"].exists)
        capture("topic-menu")
        app.buttons["Thema stummschalten"].tap()
        XCTAssertTrue(app.navigationBars["Stummschalten"].waitForExistence(timeout: 4))
        capture("mute-top")
        for name in ["30 Minuten", "1 Stunde", "2 Stunden", "8 Stunden", "Bis zur Reaktivierung"] {
            reveal(app.buttons[name])
            XCTAssertTrue(app.buttons[name].exists)
        }
        capture("mute-bottom")
        app.buttons["Bis zur Reaktivierung"].tap()
        XCTAssertTrue(app.staticTexts["Benachrichtigungen bis zur Reaktivierung stumm"].waitForExistence(timeout: 4))
        capture("muted-topic")
        app.buttons["Themenaktionen"].tap()
        reveal(app.buttons["QR-Code anzeigen"])
        app.buttons["QR-Code anzeigen"].tap()
        XCTAssertTrue(app.navigationBars["QR-Code"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.images["QR-Code für 127.0.0.1:1/aaa-nav-000"].exists)
        XCTAssertTrue(app.buttons["Teilen"].exists)
        capture("qr-show")
        app.swipeUp(); capture("qr-show-bottom")
        app.buttons["Fertig"].tap()
        app.navigationBars.buttons["Abonnierte Themen"].tap()
        capture("muted-list")
        app.buttons["Neues Abo"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Zufälliger Themenname"].exists)
        capture("add-top")
        reveal(app.buttons["QR-Code scannen"])
        capture("add-bottom")
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Scannen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Dieses Gerät hat keine Kamera. Gib Thema und Server von Hand ein."].exists)
        capture("qr-scan-no-camera")
        app.navigationBars["Scannen"].buttons["Abbrechen"].tap()
        app.navigationBars["Abo"].buttons["Abbrechen"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 4))
        capture("settings-top")
        app.swipeUp(); capture("settings-status")
        reveal(app.buttons["Neues Konto"])
        capture("settings-users")
        app.buttons["Neues Konto"].tap()
        XCTAssertTrue(app.buttons["Benutzername und Passwort"].isSelected)
        XCTAssertEqual(app.textFields["server-username"].label, "Benutzername")
        XCTAssertEqual(app.secureTextFields["server-password"].label, "Passwort")
        capture("account-password")
        reveal(app.secureTextFields["server-password"])
        capture("account-password-bottom")
        reveal(app.buttons["Zugriffstoken"], up: false)
        app.buttons["Zugriffstoken"].tap()
        XCTAssertTrue(app.buttons["Zugriffstoken"].isSelected)
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Zugriffstoken")
        capture("account-token")
        reveal(app.secureTextFields["server-access-token"])
        capture("account-token-bottom")
        app.buttons["Abbrechen"].tap()
        let savedUser = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        reveal(savedUser, up: false)
        savedUser.tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("account-editor")
        app.buttons["Abbrechen"].tap()
        reveal(app.buttons["Eigene HTTP-Header"])
        app.buttons["Eigene HTTP-Header"].tap()
        capture("server-headers")
        app.terminate()
        app.launchArguments = language + ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Neuigkeiten"].waitForExistence(timeout: 8))
        capture("whats-new-top")
        app.swipeUp(); capture("whats-new-middle")
        reveal(app.buttons["Weiter"])
        capture("whats-new-bottom")
        app.buttons["Weiter"].tap()
    }
    func testGermanEmptyList() {
        launch()
        XCTAssertTrue(app.staticTexts["Du hast noch keine Themen abonniert"].exists)
        capture("empty-list")
    }
    /// Requires the task-local HTTP fixture on loopback: it refuses /auth with 401.
    func testGermanAddLoginChoices() {
        app.launchEnvironment["NTFY_SIMULATED_QR_SCAN"] = "http://127.0.0.1:18091/zz-german-auth"
        defer { app.launchEnvironment.removeValue(forKey: "NTFY_SIMULATED_QR_SCAN") }
        launch()
        app.buttons["Neues Abo"].tap()
        reveal(app.buttons["QR-Code scannen"])
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 8))
        let server = app.textFields["Server-URL"]
        reveal(server, up: false)
        XCTAssertEqual(server.value as? String, "http://127.0.0.1:18091")
        capture("add-server-filled")
        app.navigationBars.buttons["Abonnieren"].tap()
        XCTAssertTrue(app.navigationBars["Login"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Benutzername und Passwort"].exists)
        capture("add-login-password")
        app.buttons["Zugriffstoken"].tap()
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Zugriffstoken")
        capture("add-login-token")
    }
    func testGermanLicenseScreens() {
        launch()
        app.buttons["Einstellungen"].tap()
        // Settings spans about fifteen screens at AX5; keep small, non-skipping scroll steps.
        reveal(app.buttons["Lizenzen"], attempts: 80)
        app.buttons["Lizenzen"].tap()
        XCTAssertTrue(app.navigationBars["Lizenzen"].waitForExistence(timeout: 4))
        capture("licenses-list")
        app.staticTexts["ntfy for iOS"].tap()
        let text = app.textViews["licenseText"]
        XCTAssertTrue(text.waitForExistence(timeout: 4))
        XCTAssertTrue((text.value as? String)?.contains("Permission is hereby granted") == true)
        XCTAssertFalse((text.value as? String)?.contains("Hiermit wird jeder Person") == true)
        // The file wraps "copy" and "of" onto separate lines; on a phone the paragraph is shown reflowed.
        XCTAssertTrue((text.value as? String)?.contains("obtaining a copy of this software") == true)
        capture("license-mit-top")
        text.swipeUp(); capture("license-mit-bottom")
        app.navigationBars.buttons["Lizenzen"].tap()
        app.staticTexts["Firebase"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 4))
        XCTAssertTrue((text.value as? String)?.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION") == true)
        capture("license-apache-top")
        text.swipeUp(); capture("license-apache-middle")
    }

    func testGermanCompactHeaders() {
        launch()
        app.buttons["Neues Abo"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 4))
        capture("compact-add")
        reveal(app.buttons["QR-Code scannen"])
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Scannen"].waitForExistence(timeout: 4))
        capture("compact-scanner")
        app.navigationBars["Scannen"].buttons["Abbrechen"].tap()
        app.navigationBars["Abo"].buttons["Abbrechen"].tap()
        app.buttons["Einstellungen"].tap()
        reveal(app.buttons["Neues Konto"])
        app.buttons["Neues Konto"].tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("compact-account")
        app.buttons["Abbrechen"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        reveal(saved, up: false); saved.tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("compact-edit")
        app.terminate()
        testGermanAddLoginChoices()
    }

}

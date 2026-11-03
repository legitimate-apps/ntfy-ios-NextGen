import XCTest
import UIKit
import UserNotifications
@testable import ntfy

/// The decision from iOS settings to status-screen warnings. Every warning has a test that flips only its switch.
final class NotificationSwitchesTests: XCTestCase {
    /// Everything allowed: the app is authorized, every switch is on, Background App Refresh is available, no Low Power Mode.
    private func allGood() -> NotificationSwitches {
        var s = NotificationSwitches()
        s.authorization = .authorized
        s.alertStyle = .banner
        s.lockScreen = .enabled
        s.notificationCenter = .enabled
        s.sound = .enabled
        s.scheduledDelivery = .disabled
        s.backgroundRefresh = .available
        s.lowPowerMode = false
        return s
    }

    func testAllGoodShowsNoWarnings() {
        XCTAssertEqual(allGood().warnings(), [])
    }

    func testPersistentAlertStyleCountsAsBanners() {
        var s = allGood()
        s.alertStyle = .alert
        XCTAssertEqual(s.warnings(), [])
    }

    func testBannersOffWarnsWhileLockScreenAndCenterStillShow() {
        var s = allGood()
        s.alertStyle = .none
        XCTAssertEqual(s.warnings(), [.bannersOff])
    }

    func testLockScreenOff() {
        var s = allGood()
        s.lockScreen = .disabled
        XCTAssertEqual(s.warnings(), [.lockScreenOff])
    }

    func testNotificationCenterOff() {
        var s = allGood()
        s.notificationCenter = .disabled
        XCTAssertEqual(s.warnings(), [.notificationCenterOff])
    }

    func testTwoOfThreeDisplayPlacesOffGiveTwoWarnings() {
        var s = allGood()
        s.alertStyle = .none
        s.lockScreen = .disabled
        XCTAssertEqual(s.warnings(), [.bannersOff, .lockScreenOff])
    }

    func testAllThreeDisplayPlacesOffCollapseToOneWarning() {
        var s = allGood()
        s.alertStyle = .none
        s.lockScreen = .disabled
        s.notificationCenter = .disabled
        XCTAssertEqual(s.warnings(), [.alertsHidden])
    }

    func testSoundsOff() {
        var s = allGood()
        s.sound = .disabled
        XCTAssertEqual(s.warnings(), [.soundsOff])
    }

    func testScheduledSummaryOn() {
        var s = allGood()
        s.scheduledDelivery = .enabled
        XCTAssertEqual(s.warnings(), [.scheduledSummary])
    }

    func testBackgroundRefreshDenied() {
        var s = allGood()
        s.backgroundRefresh = .denied
        XCTAssertEqual(s.warnings(), [.backgroundRefreshOff])
    }

    func testBackgroundRefreshRestrictedIsADifferentWarning() {
        var s = allGood()
        s.backgroundRefresh = .restricted
        XCTAssertEqual(s.warnings(), [.backgroundRefreshRestricted])
    }

    func testLowPowerMode() {
        var s = allGood()
        s.lowPowerMode = true
        XCTAssertEqual(s.warnings(), [.lowPowerMode])
    }

    func testUnsupportedSettingsNeverWarn() {
        var s = allGood()
        s.lockScreen = .notSupported
        s.notificationCenter = .notSupported
        s.sound = .notSupported
        s.scheduledDelivery = .notSupported
        XCTAssertEqual(s.warnings(), [])
    }

    func testWarningsKeepTheScreenOrder() {
        var s = allGood()
        s.alertStyle = .none
        s.sound = .disabled
        s.scheduledDelivery = .enabled
        s.backgroundRefresh = .denied
        s.lowPowerMode = true
        XCTAssertEqual(s.warnings(), [.bannersOff, .soundsOff, .scheduledSummary, .backgroundRefreshOff, .lowPowerMode])
    }

    /// Permission is already shown, with its own banner and button, so the switches under it would only add noise.
    func testNoSwitchWarningsWhilePermissionIsDeniedOrNotAskedYet() {
        for status in [UNAuthorizationStatus.denied, .notDetermined] {
            var s = allGood()
            s.authorization = status
            s.alertStyle = .none
            s.lockScreen = .disabled
            s.sound = .disabled
            s.scheduledDelivery = .enabled
            s.backgroundRefresh = .denied
            s.lowPowerMode = true
            XCTAssertEqual(s.warnings(), [], "\(status.rawValue)")
        }
    }

    /// Quiet (provisional) delivery has no banner, lock screen or sound by design. The rest still applies.
    func testProvisionalKeepsOnlyTheSettingsThatDelayDelivery() {
        var s = allGood()
        s.authorization = .provisional
        s.alertStyle = .none
        s.lockScreen = .disabled
        s.notificationCenter = .enabled
        s.sound = .disabled
        s.scheduledDelivery = .enabled
        s.backgroundRefresh = .denied
        s.lowPowerMode = true
        XCTAssertEqual(s.warnings(), [.scheduledSummary, .backgroundRefreshOff, .lowPowerMode])
    }

    func testEphemeralIsTreatedAsAuthorized() {
        var s = allGood()
        s.authorization = .ephemeral
        s.lockScreen = .disabled
        XCTAssertEqual(s.warnings(), [.lockScreenOff])
    }

    /// Every warning has plain copy in the app's language table, and the title differs from the detail.
    func testEveryWarningHasCopy() {
        let all: [NotificationWarning] = [.alertsHidden, .bannersOff, .lockScreenOff, .notificationCenterOff, .soundsOff,
                                          .scheduledSummary, .backgroundRefreshOff, .backgroundRefreshRestricted, .lowPowerMode]
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
        for warning in all {
            XCTAssertFalse(warning.title.isEmpty)
            XCTAssertNotEqual(warning.title, warning.detail)
            XCTAssertFalse(warning.detail.contains("\u{2014}"), "no em dashes in copy")
        }
    }

    /// The live reader fills the struct from UNNotificationSettings. Running it on the test host proves the init works
    /// and never invents a warning for a fresh host that has not asked for permission yet.
    func testReadsTheRealSettingsOnTheHost() {
        let done = expectation(description: "settings")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s = NotificationSwitches(settings: settings, backgroundRefresh: .available, lowPowerMode: false)
            XCTAssertEqual(s.authorization, settings.authorizationStatus)
            XCTAssertEqual(s.lockScreen, settings.lockScreenSetting)
            if settings.authorizationStatus == .notDetermined { XCTAssertEqual(s.warnings(), []) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}

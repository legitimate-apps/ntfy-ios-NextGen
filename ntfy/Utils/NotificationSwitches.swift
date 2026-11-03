import UIKit
import UserNotifications

/// The iOS settings that decide whether and how a notification reaches the user, as plain values
/// so `warnings()` can be tested without a device.
struct NotificationSwitches: Equatable {
    var authorization: UNAuthorizationStatus = .notDetermined
    var alertStyle: UNAlertStyle = .none
    var lockScreen: UNNotificationSetting = .notSupported
    var notificationCenter: UNNotificationSetting = .notSupported
    var sound: UNNotificationSetting = .notSupported
    var scheduledDelivery: UNNotificationSetting = .notSupported
    var backgroundRefresh: UIBackgroundRefreshStatus = .available
    var lowPowerMode = false

    init() {}

    init(settings: UNNotificationSettings, backgroundRefresh: UIBackgroundRefreshStatus, lowPowerMode: Bool) {
        authorization = settings.authorizationStatus
        alertStyle = settings.alertStyle
        lockScreen = settings.lockScreenSetting
        notificationCenter = settings.notificationCenterSetting
        sound = settings.soundSetting
        if #available(iOS 15.0, *) { scheduledDelivery = settings.scheduledDeliverySetting }
        self.backgroundRefresh = backgroundRefresh
        self.lowPowerMode = lowPowerMode
    }

    /// Only what really keeps alerts from showing or arriving on time. Only an explicit `.disabled`
    /// counts, so a setting this device does not have never warns.
    func warnings() -> [NotificationWarning] {
        // Denied and not-asked-yet already have their own row, banner and button. Switches below would be noise.
        guard authorization == .authorized || authorization == .ephemeral || authorization == .provisional else { return [] }
        var found: [NotificationWarning] = []
        // Quiet (provisional) delivery has no banner, lock screen or sound by design.
        if authorization != .provisional {
            let banners = alertStyle == .none, lock = lockScreen == .disabled, center = notificationCenter == .disabled
            if banners && lock && center {
                found.append(.alertsHidden)
            } else {
                if banners { found.append(.bannersOff) }
                if lock { found.append(.lockScreenOff) }
                if center { found.append(.notificationCenterOff) }
            }
            if sound == .disabled { found.append(.soundsOff) }
        }
        if scheduledDelivery == .enabled { found.append(.scheduledSummary) }
        switch backgroundRefresh {
        case .denied: found.append(.backgroundRefreshOff)
        case .restricted: found.append(.backgroundRefreshRestricted)
        default: break
        }
        if lowPowerMode { found.append(.lowPowerMode) }
        return found
    }
}

/// One thing that is keeping alerts away: a short title and what the user will notice and can do about it.
enum NotificationWarning: String, Equatable {
    case alertsHidden, bannersOff, lockScreenOff, notificationCenterOff, soundsOff
    case scheduledSummary, backgroundRefreshOff, backgroundRefreshRestricted, lowPowerMode

    var title: String {
        switch self {
        case .alertsHidden: return String(localized: "Alerts are hidden")
        case .bannersOff: return String(localized: "Banners are off")
        case .lockScreenOff: return String(localized: "Lock Screen alerts are off")
        case .notificationCenterOff: return String(localized: "Notification Center is off")
        case .soundsOff: return String(localized: "Sounds are off")
        case .scheduledSummary: return String(localized: "Scheduled Summary is on")
        case .backgroundRefreshOff: return String(localized: "Background App Refresh is off")
        case .backgroundRefreshRestricted: return String(localized: "Background App Refresh is restricted")
        case .lowPowerMode: return String(localized: "Low Power Mode is on")
        }
    }

    var detail: String {
        switch self {
        case .alertsHidden: return String(localized: "Banners, Lock Screen and Notification Center are all off, so new messages won't show on screen. Tap Open Settings, then turn one of them on.")
        case .bannersOff: return String(localized: "New messages won't pop up on screen. Tap Open Settings, then turn on Banners.")
        case .lockScreenOff: return String(localized: "New messages won't show while your device is locked. Tap Open Settings, then turn on Lock Screen.")
        case .notificationCenterOff: return String(localized: "Messages you miss won't stay in Notification Center. Tap Open Settings, then turn on Notification Center.")
        case .soundsOff: return String(localized: "New messages arrive without a sound. Tap Open Settings, then turn on Sounds.")
        case .scheduledSummary: return String(localized: "Regular alerts are held and shown together at set times, not right away. Tap Open Settings, then choose Immediate Delivery.")
        case .backgroundRefreshOff: return String(localized: "iOS won't let the app update in the background, so messages can arrive late or only when you open it. Turn it on in Settings → General → Background App Refresh.")
        case .backgroundRefreshRestricted: return String(localized: "Screen Time or device management blocks background updates, so messages can arrive late. Only whoever set the restriction can change it.")
        case .lowPowerMode: return String(localized: "iOS pauses background updates to save battery, so messages can arrive late. Turn it off in Settings → Battery.")
        }
    }
}

extension NotificationSwitches {
    /// Simulator screenshots only, not compiled into Release. Launch with
    /// `-NTFYStatusWarnings banners,lockscreen,center,sounds,summary,refresh,restricted,lowpower` (any subset, or `none`):
    /// the result starts from "authorized, everything on" and turns each named switch the wrong way.
    func applyingDebugOverride() -> NotificationSwitches {
        #if DEBUG
        guard let spec = UserDefaults.standard.string(forKey: "NTFYStatusWarnings") else { return self }
        var s = self
        s.authorization = .authorized
        s.alertStyle = .banner; s.lockScreen = .enabled; s.notificationCenter = .enabled; s.sound = .enabled
        s.scheduledDelivery = .disabled; s.backgroundRefresh = .available; s.lowPowerMode = false
        for token in spec.lowercased().split(separator: ",") {
            switch token {
            case "banners": s.alertStyle = .none
            case "lockscreen": s.lockScreen = .disabled
            case "center": s.notificationCenter = .disabled
            case "sounds": s.sound = .disabled
            case "summary": s.scheduledDelivery = .enabled
            case "refresh": s.backgroundRefresh = .denied
            case "restricted": s.backgroundRefresh = .restricted
            case "lowpower": s.lowPowerMode = true
            default: break
            }
        }
        return s
        #else
        return self
        #endif
    }
}

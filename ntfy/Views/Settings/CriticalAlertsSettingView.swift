//
//  CriticalAlertsSettingView.swift
//  ntfy
//
//  Created by Alek Michelson on 6/8/26.
//

import SwiftUI
import UserNotifications

/// UI decisions from the system's settings, never from a saved opt-in alone.
struct UrgentAlertsState: Equatable {
    enum Status: String {
        case on = "On"
        case off = "Off"
        case notRequested = "Not requested yet"
        case notificationsOff = "Notifications off"
    }

    static let explanation = String(localized: "Priority 4 and 5 messages are Time Sensitive. They can break through Focus and the Notification Summary when allowed in the Settings app, including your Focus settings.")
    static let criticalUnavailable = String(localized: "Critical alerts, which play sound even when your device is silenced, need special approval from Apple and aren't offered in this app.")
    static let criticalExplanation = String(localized: "When enabled, priority 5 messages can play sound even when silenced.")

    let status: Status
    let showsCriticalToggle: Bool
    var showsSettingsButton: Bool { status != .on && status != .notRequested }
    var criticalText: String { showsCriticalToggle ? Self.criticalExplanation : Self.criticalUnavailable }

    init(timeSensitive: UNNotificationSetting, critical: UNNotificationSetting,
         authorization: UNAuthorizationStatus) {
        switch authorization {
        case .authorized, .ephemeral:
            status = timeSensitive == .enabled ? .on : .off
        case .notDetermined:
            status = .notRequested
        case .provisional:
            // Quiet provisional delivery cannot break through Focus.
            status = .off
        default:
            status = .notificationsOff
        }
        showsCriticalToggle = critical != .notSupported
    }
}

struct UrgentAlertsSettingView: View {
    @EnvironmentObject private var delegate: AppDelegate

    private var state: UrgentAlertsState {
        UrgentAlertsState(timeSensitive: delegate.timeSensitiveSetting,
                          critical: delegate.criticalAlertSetting,
                          authorization: delegate.notificationAuthorizationStatus)
    }

    var body: some View {
        Section(
            header: Text(String(localized: "Urgent alerts")),
            footer: VStack(alignment: .leading, spacing: 8) {
                Text(UrgentAlertsState.explanation)
                Text(state.criticalText)
            }
        ) {
            NotificationStatusRow(title: String(localized: "Time Sensitive notifications"),
                                  value: NSLocalizedString(state.status.rawValue, comment: ""))
            if state.status == .notRequested {
                Button(DeliveryHealthCopy.allowNotifications) {
                    delegate.requestStandardNotificationAuthorization()
                }
            }
            if state.showsSettingsButton {
                Button(DeliveryHealthCopy.openSettings) {
                    delegate.openNotificationSettings()
                }
            }
            if state.showsCriticalToggle {
                CriticalAlertsSettingView()
            }
        }
        .onAppear { delegate.refreshNotificationSettings() }
    }
}

struct CriticalAlertsSettingView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @FetchRequest(sortDescriptors: []) private var prefs: FetchedResults<Preference>
    @State private var showingSettingsAlert = false

    private var criticalAlertsEnabled: Bool {
        prefs
            .first { $0.key == Store.prefKeyCriticalAlertsEnabled }?
            .value == "true"
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { criticalAlertsEnabled },
            set: handleToggleChanged
        )) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                    .foregroundColor(.red)
                    .font(.system(size: 22))

                Text(String(localized: "Critical Alerts"))
                    .foregroundColor(.primary)
            }
        }
        .alert(String(localized: "Enable Critical Alerts"), isPresented: $showingSettingsAlert) {
            Button(DeliveryHealthCopy.openSettings) {
                delegate.openNotificationSettings()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Critical alerts were not allowed. You can enable them for ntfy in the Settings app under Notifications."))
        }
    }

    private func handleToggleChanged(_ enabled: Bool) {
        guard enabled else {
            store.saveCriticalAlertsEnabled(false)
            return
        }

        delegate.requestCriticalAlertsAuthorization { isAuthorized in
            if isAuthorized {
                store.saveCriticalAlertsEnabled(true)
            } else {
                store.saveCriticalAlertsEnabled(false)
                showingSettingsAlert = true
            }
        }
    }
}

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
        case notificationsOff = "Notifications off"
    }

    static let explanation = "Priority 4 and 5 messages are Time Sensitive. They can break through Focus and the Notification Summary when allowed in iOS settings, including your Focus settings."
    static let criticalUnavailable = "iOS critical alerts play sound even when silenced. They need Apple's approval and aren't available yet."
    static let criticalExplanation = "When enabled, priority 5 messages can play sound even when silenced."

    let status: Status
    let showsCriticalToggle: Bool
    var showsSettingsButton: Bool { status != .on }
    var criticalText: String { showsCriticalToggle ? Self.criticalExplanation : Self.criticalUnavailable }

    init(timeSensitive: UNNotificationSetting, critical: UNNotificationSetting,
         authorization: UNAuthorizationStatus) {
        switch authorization {
        case .authorized, .ephemeral:
            status = timeSensitive == .enabled ? .on : .off
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
        Section(header: Text("Urgent alerts")) {
            Text(UrgentAlertsState.explanation)
            VStack(alignment: .leading, spacing: 4) {
                Text("Time Sensitive notifications")
                Text(state.status.rawValue)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            if state.showsSettingsButton {
                Button("Open Notification Settings") {
                    delegate.openNotificationSettings()
                }
            }
            if state.showsCriticalToggle {
                CriticalAlertsSettingView()
            }
            Text(state.criticalText)
                .font(.footnote)
                .foregroundColor(.secondary)
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
                    .foregroundColor(.red)
                    .font(.system(size: 22))

                Text("Critical Alerts")
                    .foregroundColor(.primary)
            }
        }
        .alert("Enable Critical Alerts", isPresented: $showingSettingsAlert) {
            Button("Open Notification Settings") {
                delegate.openNotificationSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Critical alerts were not allowed. You can enable them in the iOS notification settings for ntfy.")
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

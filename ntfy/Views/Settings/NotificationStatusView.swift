import SwiftUI
import UIKit

struct NotificationPermissionBanner: View {
    @EnvironmentObject private var delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DeliveryHealthCopy.notificationsOff)
                .fixedSize(horizontal: false, vertical: true)
            Button(DeliveryHealthCopy.openSettings) { delegate.openNotificationSettings() }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct NotificationStatusView: View {
    @EnvironmentObject private var delegate: AppDelegate
    @StateObject private var subscriptions = SubscriptionsObservable()
    @Environment(\.scenePhase) private var scenePhase
    @State private var repairing = false
    @State private var result: String?
    @State private var repairID = UUID()

    private var pendingCount: Int { subscriptions.subscriptions.filter { !$0.fcmSubscribed }.count }

    var body: some View {
        Section(header: Text(DeliveryHealthCopy.status)) {
            statusRow(DeliveryHealthCopy.permission,
                      DeliveryHealthCopy.permissionLabel(delegate.notificationAuthorizationStatus))
            statusRow(DeliveryHealthCopy.phoneRegistration,
                      delegate.hasPhoneRegistration ? DeliveryHealthCopy.registered : DeliveryHealthCopy.waiting)
            statusRow(DeliveryHealthCopy.pushRegistration,
                      delegate.hasPushRegistration ? DeliveryHealthCopy.registered : DeliveryHealthCopy.waiting)
            statusRow(DeliveryHealthCopy.pendingTopics, String(pendingCount))
            if delegate.notificationAuthorizationStatus == .notDetermined {
                Button(DeliveryHealthCopy.allowNotifications) {
                    delegate.requestStandardNotificationAuthorization { result = nil }
                }
            } else {
                Button(DeliveryHealthCopy.openSettings) { delegate.openNotificationSettings() }
            }
            Button(repairing ? DeliveryHealthCopy.repairing : DeliveryHealthCopy.repair, action: repair)
                .disabled(repairing)
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { delegate.refreshNotificationSettings() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                result = nil
                delegate.refreshNotificationSettings()
            }
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(value).font(.subheadline).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func repair() {
        repairing = true
        result = nil
        let id = UUID()
        repairID = id
        UIApplication.shared.registerForRemoteNotifications()
        RegistrationRepair.wait(isReady: { delegate.hasPhoneRegistration && delegate.hasPushRegistration }) {
            guard repairID == id, repairing else { return }
            FcmSubscriptionReconciler.shared.reconcile(reason: "user requested repair") {
                DispatchQueue.main.async {
                    guard repairID == id else { return }
                    delegate.refreshNotificationSettings {
                        guard repairID == id else { return }
                        repairing = false
                        let registered = delegate.hasPhoneRegistration && delegate.hasPushRegistration
                        result = NotificationHealth.repairResult(permission: delegate.notificationAuthorizationStatus,
                            registered: registered, bindingsComplete: FcmSubscriptionReconciler.shared.isPushSetupComplete)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard repairID == id, repairing else { return }
            repairing = false
            result = DeliveryHealthCopy.repairTimeout
            repairID = UUID() // A late callback must not overwrite the timeout or a later attempt.
        }
    }
}

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
            ForEach(selfHostedSubscriptions, id: \.objectID) { subscription in
                NavigationLink(destination: RelayTopicCheckView(subscription: subscription)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Check self-hosted wake-ups"))
                        Text(subscription.displayName()).font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
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

    private var selfHostedSubscriptions: [Subscription] {
        subscriptions.subscriptions.filter {
            Self.offersWakeupCheck(baseUrl: $0.baseUrl ?? "")
        }
    }

    static func offersWakeupCheck(baseUrl: String) -> Bool {
        guard RelayCheck.isSecureBase(baseUrl), let hostname = URL(string: baseUrl)?.host?.lowercased() else { return false }
        let host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let appHost = URL(string: Config.appBaseUrl)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host != appHost && host != "ntfy-me.com" && host != "ntfy.sh"
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


/// Consent is local to a selected topic. The relay API never sees this message or its credentials.
struct RelayTopicCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    let subscription: Subscription
    @StateObject private var check = RelayCheck()

    var body: some View {
        RelayCheckContentView(topicName: subscription.displayName(), baseUrl: subscription.baseUrl ?? "",
            state: check.state,
            prepare: { check.prepare(baseUrl: subscription.baseUrl ?? "", topic: subscription.topic ?? "") },
            approve: sendTest, cancel: check.cancel)
            .onDisappear { check.cancel() }
            .onChange(of: scenePhase) { if $0 != .active { check.cancel() } }
    }

    private func sendTest() {
        let keyState = Store.shared.topicKeyState(for: subscription)
        check.approve { completion in
            guard keyState != .unavailable else {
                completion(String(localized: "The encryption key is unavailable. Nothing was sent."))
                return
            }
            ApiService.shared.publish(subscription: subscription,
                user: Store.shared.getBasicUser(baseUrl: subscription.baseUrl ?? ""),
                message: String(localized: "This is a test notification from NTFY me (wake-up forwarding check)."), title: String(localized: "Wake-up forwarding test"),
                encryptionKey: keyState.key,
                completionHandler: { completion(nil) }, failureHandler: { completion($0.userMessage) })
        }
    }
}


/// Pure presentation shared by the live flow and the simulator visual checks.
struct RelayCheckContentView: View {
    let topicName: String
    let baseUrl: String
    let state: RelayCheck.State
    let prepare: () -> Void
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            Section(header: Text(String(localized: "Self-hosted wake-ups"))) {
                Text(topicName).fixedSize(horizontal: false, vertical: true)
                Text(baseUrl).font(.footnote).foregroundColor(.secondary)
                Text(String(localized: "Check whether ntfy-me.com receives forwarded wake-ups for this topic. This cannot prove delivery to your phone."))
                    .fixedSize(horizontal: false, vertical: true)
                if state != .consent {
                    Button(String(localized: "Check relay support")) {
                        prepare()
                    }.disabled(state.isBusy)
                }
            }
            if state == .consent {
                Section(header: Text(String(localized: "Send a visible test?"))) {
                    Text(String(localized: "This sends one ordinary test message to this topic, visible to everyone subscribed. It uses your topic server's credentials and encryption settings. The relay receives only the topic hash, without your message or credentials."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Send one test message"), action: approve)
                    Button(String(localized: "Cancel"), action: cancel)
                }
            }
            if let message = state.message {
                Section(header: Text(String(localized: "Check result"))) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("relay-check-result")
                    if state.isBusy {
                        Button(String(localized: "Cancel check"), action: cancel)
                    }
                }
            }
            Section(header: Text(String(localized: "Server setup"))) {
                Text(String(localized: "Your server's upstream-base-url must be https://ntfy-me.com. Its configured base-url must exactly match the server address used for this subscription, including scheme, port, path and spelling. The relay keeps only recent acceptance times (up to 2 minutes); it does not report phone delivery."))
                    .font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(String(localized: "Wake-up check"))
    }

}

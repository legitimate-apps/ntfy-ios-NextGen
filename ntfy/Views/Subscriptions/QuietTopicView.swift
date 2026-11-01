import SwiftUI
import UserNotifications

struct QuietTopicButton: View {
    @Binding var showingOptions: Bool
    var body: some View {
        Button { showingOptions = true } label: {
            Label(String(localized: "Alert if quiet"), systemImage: "timer")
        }
    }
}

struct QuietTopicView: View {
    @ObservedObject var subscription: Subscription
    @Environment(\.presentationMode) private var presentationMode
    @State private var selected: TimeInterval = 0
    @State private var saving = false
    @State private var failed = false
    @State private var notificationsDenied = false
    private let alerts = QuietTopicAlerts.shared
    private var identity: String { subscription.objectID.uriRepresentation().absoluteString }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(subscription.shortDisplayName()), footer: Text(String(localized: "Get one alert when no message arrives within the chosen time, even if this topic is muted. A new message starts the timer again. A quiet alert can also mean this phone isn't receiving messages, including when it is offline."))) {
                    choice(0, title: String(localized: "Off"))
                    ForEach(QuietTopicAlerts.intervals, id: \.self) { interval in
                        choice(interval, title: QuietTopicAlerts.intervalTitle(interval))
                    }
                }
                if notificationsDenied {
                    Section { Text(String(localized: "Allow notifications in Settings to receive quiet alerts.")) }
                }
            }
            .navigationTitle(String(localized: "Alert if quiet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { presentationMode.wrappedValue.dismiss() }
            } }
            .onAppear {
                selected = alerts.interval(for: identity)
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    DispatchQueue.main.async { notificationsDenied = settings.authorizationStatus == .denied }
                }
            }
            .alert(String(localized: "Couldn't schedule quiet alert"), isPresented: $failed) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { Text(String(localized: "Try selecting the interval again.")) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func choice(_ interval: TimeInterval, title: String) -> some View {
        Button {
            saving = true
            if interval == 0 { saveChoice(interval); return }
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
                        DispatchQueue.main.async {
                            if allowed { saveChoice(interval) }
                            else { saving = false; notificationsDenied = true }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        if settings.authorizationStatus == .denied { saving = false; notificationsDenied = true }
                        else { saveChoice(interval) }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if selected == interval { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }
        .disabled(saving)
        .accessibilityAddTraits(selected == interval ? .isSelected : [])
        .accessibilityIdentifier("quiet-interval-\(Int(interval))")
    }

    private func saveChoice(_ interval: TimeInterval) {
        alerts.configure(identity: identity, baseUrl: subscription.baseUrl ?? "", topic: subscription.topic ?? "",
                         title: subscription.shortDisplayName(), interval: interval) { error in
            DispatchQueue.main.async {
                saving = false
                if error == nil { selected = interval } else { failed = true }
            }
        }
    }

}

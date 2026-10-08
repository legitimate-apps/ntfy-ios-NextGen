import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ActiveAlert {
    case clear, unsubscribe, selected, encryptionUnavailable, publishFailed
}


struct NotificationListView: View {
    private let tag = "NotificationListView"
    
    @EnvironmentObject private var delegate: AppDelegate
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    
    @ObservedObject var subscription: Subscription
    // @StateObject, not @ObservedObject: this view constructs the observable in its own
    // initializer, and @ObservedObject does not own what it is handed. Every rebuild of the view
    // struct — which LazyView makes more likely, since it re-runs its autoclosure whenever its body
    // is re-evaluated — would construct a fresh observable and re-run its per-topic fetch, throwing
    // away the live NSFetchedResultsController. Same ownership bug fixed for SubscriptionsObservable
    // in #36; this is its sibling.
    @StateObject var notificationsModel: NotificationsObservable
    
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<Notification>()
    
    @State private var showAlert = false
    @State private var activeAlert: ActiveAlert = .clear
    @State private var showCopiedConfirmation = false
    @State private var showRenameSheet = false
    @State private var showEncryptionSheet = false
    @State private var publishError = ""
    @State private var draftDisplayName = ""
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }

    init(subscription: Subscription) {
        self.subscription = subscription
        // StateObject's wrappedValue is an autoclosure, so this is evaluated once for the view's
        // lifetime rather than on every struct rebuild.
        _notificationsModel = StateObject(wrappedValue: NotificationsObservable(subscriptionID: subscription.objectID))
    }

    var body: some View {
        notificationList
            .refreshable {
                _ = await pollOnce()
            }
            .onAppear {
                // Opening the topic counts as reading it, so the badge clears immediately rather
                // than lingering behind the user. Anything the live poll below pulls in afterwards
                // stays unread, which is what you want — it hadn't arrived when you opened.
                store.setRead(true, forSubscription: subscription)
            }
            // While this topic is on screen and the app is active, check for new messages: once right
            // away (opening a topic, or coming back to the app), then every 10 s, each check starting
            // only after the previous one ended, backing off while the server fails. A push normally
            // brings messages in live, but there is none when notifications are off ("Not now" or
            // denied), on a self-hosted server without `upstream-base-url`, or in the simulator; a
            // message sent while the topic was open then stayed invisible until the user left and came
            // back. SwiftUI cancels this task when the view goes away or the scene phase changes.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                var failures = 0
                while !Task.isCancelled {
                    failures = await pollOnce(skipIfInFlight: true) ? 0 : failures + 1
                    let delay = LivePollSchedule.delay(afterConsecutiveFailures: failures)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
    }

    /// One poll; true unless it failed. The live loop skips while its previous poll is still out
    /// (see `PollGuard`); pull to refresh always polls.
    private func pollOnce(skipIfInFlight: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            subscriptionManager.pollWithOutcome(subscription, skipIfInFlight: skipIfInFlight) { outcome in
                continuation.resume(returning: outcome.succeeded)
            }
        }
    }
    
    private var notificationList: some View {
        Group {
            if editMode == .active {
                List(selection: $selection) {
                    notificationRows
                }
            } else {
                List {
                    notificationRows
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, self.$editMode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Match the list row's primary line: tapping "basket-alerts" opening a screen
                // titled "ntfy.<long-host>/basket-alerts" read as a different topic.
                Text(subscription.shortDisplayName())
                    .font(.headline)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if (self.editMode == .active) {
                    editButton
                } else {
                    Menu {
                        if notificationsModel.notifications.count > 0 {
                            editButton
                        }
                        Button("Rename") {
                            self.draftDisplayName = subscription.customDisplayName ?? ""
                            self.showRenameSheet = true
                        }
                        Button("End-to-end encryption") {
                            self.showEncryptionSheet = true
                        }
                        // The publish URL is what every script needs. Once a topic has messages the
                        // empty-state copy buttons are gone, so keep it one tap away here.
                        Button("Copy publish URL") {
                            if let baseUrl = subscription.baseUrl {
                                UIPasteboard.general.string = PublishCommand.publishUrl(
                                    baseUrl: baseUrl, topic: subscription.topicName())
                                showCopyConfirmation()
                            }
                        }
                        Button("Send test notification") {
                            self.sendTestNotification()
                        }
                        if notificationsModel.notifications.count > 0 {
                            Button("Clear all notifications") {
                                self.showAlert = true
                                self.activeAlert = .clear
                            }
                        }
                        Button("Unsubscribe") {
                            self.showAlert = true
                            self.activeAlert = .unsubscribe
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .padding([.leading], 40)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if (self.editMode == .active) {
                    Button(action: {
                        self.showAlert = true
                        self.activeAlert = .selected
                    }) {
                        Text("Delete")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .alert(isPresented: $showAlert) {
            switch activeAlert {
            case .clear:
                return Alert(
                    title: Text("Clear notifications"),
                    message: Text("Do you really want to delete all of the notifications in this topic?"),
                    primaryButton: .destructive(
                        Text("Permanently delete"),
                        action: deleteAll
                    ),
                    secondaryButton: .cancel())
            case .unsubscribe:
                return Alert(
                    title: Text("Unsubscribe"),
                    message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                    primaryButton: .destructive(
                        Text("Unsubscribe"),
                        action: unsubscribe
                    ),
                    secondaryButton: .cancel())
            case .selected:
                return Alert(
                    title: Text("Delete"),
                    message: Text("Do you really want to delete these selected notifications?"),
                    primaryButton: .destructive(
                        Text("Delete"),
                        action: deleteSelected
                    ),
                    secondaryButton: .cancel())
            case .publishFailed:
                return Alert(title: Text("Test notification not sent"), message: Text(publishError))
            case .encryptionUnavailable:
                return Alert(
                    title: Text("Not sent"),
                    message: Text("This topic is end-to-end encrypted, but its password can't be read right now, so the test message would go out unencrypted. Try again after unlocking your phone, or set the password again.")
                )
            }
        }
        .overlay(Group {
            if showCopiedConfirmation {
                Text("Copied to Clipboard")
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.cornerRadius(20))
                    .shadow(radius: 5)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .onAppear {
            cancelSubscriptionNotifications()
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showEncryptionSheet) {
            TopicEncryptionView(subscription: subscription)
                .environmentObject(store)
        }
        .onDisappear {
            if delegate.selectedBaseUrl == subscription.urlString() {
                delegate.selectedBaseUrl = nil
            }
        }
    }
    
    /// The saved login and custom headers for this topic's server, so the copied commands ask for
    /// them instead of publishing anonymously and failing. Names only: no secret leaves the Keychain.
    private func publishAuth(baseUrl: String) -> PublishCommand.Auth {
        PublishCommand.Auth(
            username: store.getBasicUser(baseUrl: baseUrl)?.username,
            headerNames: KeychainCredentialStore.shared.httpHeaders(baseUrl: baseUrl).keys.sorted()
        )
    }

    @ViewBuilder
    private var notificationRows: some View {
        // The empty state is a row of the list, not an overlay on top of it. As an overlay it sat over
        // the (empty) list and swallowed the drag, so pull-to-refresh did nothing on a new topic, and on
        // a small phone its text ran off the screen with no way to scroll to the copy buttons.
        if notificationsModel.notifications.isEmpty && editMode == .inactive, let baseUrl = subscription.baseUrl {
            TopicPublishHelpView(
                baseUrl: baseUrl,
                topic: subscription.topicName(),
                encrypted: subscription.encrypted,
                auth: publishAuth(baseUrl: baseUrl),
                onCopy: showCopyConfirmation
            )
            .listRowSeparator(.hidden)
        }
        ForEach(notificationsModel.notifications, id: \.self) { notification in
            NotificationRowView(
                notification: notification,
                onCopyMessage: showCopyConfirmation
            )
        }
    }
    
    private var renameSheet: some View {
        NavigationView {
            Form {
                Section(footer: Text("Set a custom name for this subscription. Leave empty to use the topic name.")) {
                    TextField(subscription.topicName(), text: $draftDisplayName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Display name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showRenameSheet = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.updateSubscription(subscription: subscription, displayName: draftDisplayName)
                        showRenameSheet = false
                    }
                }
            }
        }
    }

    private var editButton: some View {
        if editMode == .inactive {
            return Button(action: {
                self.editMode = .active
                self.selection = Set<Notification>()
            }) {
                Text("Select messages")
            }
        } else {
            return Button(action: {
                self.editMode = .inactive
                self.selection = Set<Notification>()
            }) {
                Text("Done")
            }
        }
    }
    
    private func sendTestNotification() {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Cannot send test notification: subscription base URL is missing")
            return
        }

        let possibleTags: Array<String> = ["warning", "skull", "success", "triangular_flag_on_post", "de", "us", "dog", "cat", "rotating_light", "bike", "backup", "rsync", "this-s-a-tag", "ios"]
        let priority = Int.random(in: 1..<6)
        let tags = Array(possibleTags.shuffled().prefix(Int.random(in: 0..<4)))

        // Never fall back to plaintext on an encrypted topic whose key can't be read right now.
        let keyState = store.topicKeyState(for: subscription)
        if keyState == .unavailable {
            activeAlert = .encryptionUnavailable
            showAlert = true
            return
        }
        let user = store.getBasicUser(baseUrl: baseUrl)
        ApiService.shared.publish(
            subscription: subscription,
            user: user,
            message: "This is a test notification from the ntfy iOS app. It has a priority of \(priority). If you send another one, it may look different.",
            title: "Test: You can set a title if you like",
            priority: priority,
            tags: tags,
            // A topic with a password gets an encrypted test message, so this button also proves the
            // password round-trips through the server.
            encryptionKey: keyState.key,
            completionHandler: {
                DispatchQueue.main.async {
                    subscriptionManager.poll(subscription)
                }
            },
            failureHandler: { error in
                DispatchQueue.main.async {
                    publishError = error.userMessage
                    activeAlert = .publishFailed
                    showAlert = true
                }
            }
        )
    }
    
    private func unsubscribe() {
        subscriptionManager.unsubscribe(subscription)
        delegate.selectedBaseUrl = nil
    }
    
    private func deleteAll() {
        store.delete(allNotificationsFor: subscription)
    }
    
    private func deleteSelected() {
        store.delete(notifications: selection)
        selection = Set<Notification>()
        editMode = .inactive
    }
    
    private func cancelSubscriptionNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { notification in
                    let userInfo = notification.request.content.userInfo
                    if let baseUrl = userInfo["base_url"] as? String, let topic = userInfo["topic"] as? String {
                        // `matches` normalizes both sides. Comparing the payload's raw base URL
                        // against the normalized stored one meant a self-hosted server configured
                        // with a trailing slash never matched, so opening the topic left its banners
                        // sitting in Notification Center until the user cleared them by hand.
                        return subscription.matches(baseUrl: baseUrl, topic: topic)
                    }
                    return false
                }
                .map { notification in
                    notification.request.identifier
                }
            if !ids.isEmpty {
                Log.d(tag, "Cancelling \(ids.count) notification(s) from notification center")
                notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
    
    private func showCopyConfirmation() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCopiedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopiedConfirmation = false
            }
        }
    }
    
}

/// What a new, empty topic shows: ready-to-run publish commands with the full https:// URL, each
/// copyable with one tap, plus where to learn more. See `PublishCommand` for why the scheme matters.
struct TopicPublishHelpView: View {
    let baseUrl: String
    let topic: String
    let encrypted: Bool
    var auth: PublishCommand.Auth = .none
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No messages yet")
                .font(.title3.bold())
            Text("Send a message to this topic from any computer, server or script. Copy a command and "
                 + "run it in a terminal:")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            copyBlock(title: "Send a message",
                      text: PublishCommand.simple(baseUrl: baseUrl, topic: topic, auth: auth))
            copyBlock(title: "With a title and high priority",
                      text: PublishCommand.titled(baseUrl: baseUrl, topic: topic, auth: auth))
            copyBlock(title: "Publish URL",
                      text: PublishCommand.publishUrl(baseUrl: baseUrl, topic: topic))
            if !auth.isEmpty {
                Text(authNote)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if encrypted {
                Text("These commands send unencrypted messages. For encrypted ones, open End-to-end "
                     + "encryption in the ••• menu.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let help = URL(string: Config.helpUrl) {
                Link("Quick start and more examples", destination: help)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            if let docs = URL(string: Config.docsUrl) {
                Link("Full ntfy reference docs", destination: docs)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 24)
    }

    private var authNote: String {
        var lines: [String] = []
        if let username = auth.username {
            lines.append("This server uses your login (\(username)). curl asks for the password, so it "
                         + "is never in the copied text.")
        }
        if !auth.headerNames.isEmpty {
            lines.append("Replace \(PublishCommand.headerValuePlaceholder) with the value of "
                         + auth.headerNames.joined(separator: ", ") + " from Settings.")
        }
        lines.append("Sending needs write access to this topic; read access alone isn't enough.")
        return lines.joined(separator: " ")
    }

    private func copyBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Button {
                UIPasteboard.general.string = text
                onCopy()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    // Wrap, never truncate: a command with an ellipsis in it is worse than none.
                    Text(verbatim: text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.accentColor)
                }
                .padding(10)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy: \(title)")
            .accessibilityValue(text)
        }
    }
}

struct NotificationListView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        Group {
            let subscriptionWithNotifications = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
            let subscriptionWithoutNotifications = store.makeSubscription(store.context, "announcements", Store.sampleMessages["announcements"]!)
            NotificationListView(subscription: subscriptionWithNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
            NotificationListView(subscription: subscriptionWithoutNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
        }
    }
}

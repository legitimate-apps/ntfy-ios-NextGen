import SwiftUI
import CoreData
import FirebaseMessaging
import UserNotifications
import UIKit

struct SubscriptionListView: View {
    let tag = "SubscriptionList"
    
    @EnvironmentObject private var store: Store
    // @StateObject, not @ObservedObject: `SubscriptionsObservable()` is constructed here, and
    // @ObservedObject does not own what it is given — SwiftUI is free to rebuild this view's struct
    // and hand it a freshly constructed observable, throwing away the live NSFetchedResultsController
    // (and its delegate registration) mid-flight. @StateObject makes the view the owner, so exactly
    // one controller is created for the view's lifetime.
    @StateObject private var subscriptionsModel = SubscriptionsObservable()
    @ObservedObject private var launchExperience = LaunchExperience.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddDialog = false
    /// Topics `RetiredDefaultServerMigration` moved to ntfy-me.com that the user hasn't been told about.
    @State private var movedTopicsNotice: [String] = []
    private let appGroupDefaults = UserDefaults(suiteName: Store.appGroup) ?? .standard
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        NavigationView {
            if #available(iOS 15.0, *) {
                subscriptionList
                    .refreshable {
                        pollSubscriptions()
                    }
            } else {
                subscriptionList
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                pollSubscriptions()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $launchExperience.showingWhatsNew,
               onDismiss: launchExperience.dismissWhatsNew) {
            WhatsNewView(entries: launchExperience.entries) {
                launchExperience.showingWhatsNew = false
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            launchExperience.prepare(hasSubscriptions: !(store.getSubscriptions() ?? []).isEmpty,
                movedTopicsPending: !RetiredDefaultServerMigration.pendingNoticeTopics(defaults: appGroupDefaults).isEmpty)
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            guard movedTopicsNotice.isEmpty, !showingAddDialog else { return }
            launchExperience.presentWhatsNew()
        }
    }
    
    private var subscriptionList: some View {
        List {
            ForEach(subscriptionsModel.subscriptions) { subscription in
                SubscriptionItemNavView(subscription: subscription,
                                        summary: subscriptionsModel.summaries[subscription.objectID])
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle("Subscribed topics")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    self.showingAddDialog = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay(Group {
            if subscriptionsModel.subscriptions.isEmpty {
                VStack {
                    Text("It looks like you don't have any subscriptions yet")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.bottom)

                    Text("Tap + to create a topic. Then send it a message from any computer or script, and it shows up here and as a notification.")
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.bottom)
                    if let help = URL(string: Config.helpUrl) {
                        Link("Quick start at \(shortUrl(url: normalizeBaseUrl(Config.helpUrl)))", destination: help)
                    }
                }
                .padding(40)
            }
        })
        .sheet(isPresented: $showingAddDialog) {
            SubscriptionAddView(isShowing: $showingAddDialog)
        }
        .onAppear {
            // Ensures subscription count stays up to date, so a pull to refresh isn't required
            pollSubscriptions()
            movedTopicsNotice = RetiredDefaultServerMigration.pendingNoticeTopics(defaults: appGroupDefaults)
        }
        .alert(isPresented: Binding(
            get: { !movedTopicsNotice.isEmpty },
            set: { if !$0 { dismissMovedTopicsNotice() } }
        )) {
            Alert(
                title: Text(movedTopicsNotice.count == 1 ? "Your topic moved to ntfy-me.com" : "Your topics moved to ntfy-me.com"),
                message: Text(RetiredDefaultServerMigration.noticeMessage(topics: movedTopicsNotice)),
                dismissButton: .default(Text("OK")) { dismissMovedTopicsNotice() }
            )
        }
    }

    private func dismissMovedTopicsNotice() {
        RetiredDefaultServerMigration.dismissNotice(defaults: appGroupDefaults)
        movedTopicsNotice = []
    }

    private func pollSubscriptions() {
        subscriptionsModel.subscriptions.forEach { subscription in
            subscriptionManager.poll(subscription)
        }
    }
}

struct SubscriptionItemNavView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @ObservedObject var subscription: Subscription
    let summary: Store.SubscriptionSummary?
    @State private var unsubscribeAlert = false
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        if #available(iOS 15.0, *) {
            subscriptionRow
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    // Mirrors Messages: swipe right to toggle read state, and a full swipe commits
                    // it without waiting for a tap.
                    Button {
                        toggleRead()
                    } label: {
                        // From the summary, not `subscription.hasUnread()`. SwiftUI builds this
                        // label while building the row, not when the user swipes, and hasUnread()
                        // scans the to-many relationship — which would fault every topic's whole
                        // history during list rendering and undo the point of the aggregate.
                        // `toggleRead()` still asks the object directly: by then the user has acted
                        // and a fresh authoritative read is worth one fault.
                        let unread = (summary?.unread ?? subscription.unreadCount()) > 0
                        Label(unread ? "Read" : "Unread",
                              systemImage: unread ? "envelope.open.fill" : "envelope.badge.fill")
                    }
                    .tint(Color.accentColor)

                    Button {
                        togglePinned()
                    } label: {
                        Label(subscription.pinned ? "Unpin" : "Pin",
                              systemImage: subscription.pinned ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(PinBadge.tint)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        self.unsubscribeAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash.circle")
                    }
                }
        } else {
            subscriptionRow
        }
    }

    /// Flip the whole topic's read state, with the same light impact Messages gives when a full
    /// swipe commits. SwiftUI hands us one callback for both the tap and the full swipe, so the
    /// haptic fires for either — there is no API to distinguish them.
    private func toggleRead() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if subscription.hasUnread() {
            store.setRead(true, forSubscription: subscription)
        } else {
            // Only the newest message comes back unread — see Store.markMostRecentUnread.
            store.markMostRecentUnread(subscription: subscription)
        }
    }
    
    private func togglePinned() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.setPinned(!subscription.pinned, forSubscription: subscription)
    }

    private var subscriptionRow: some View {
        ZStack {
            NavigationLink(
                destination: LazyView(NotificationListView(subscription: subscription)),
                tag: subscription.urlString(),
                selection: $delegate.selectedBaseUrl
            ) {
                EmptyView()
            }
            .opacity(0.0)
            .buttonStyle(PlainButtonStyle())
            
            SubscriptionItemRowView(subscription: subscription, summary: summary)
        }
        .accessibilityElement(children: .combine)
        .alert(isPresented: $unsubscribeAlert) {
            Alert(
                title: Text("Unsubscribe"),
                message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                primaryButton: .destructive(
                    Text("Unsubscribe"),
                    action: {
                        self.subscriptionManager.unsubscribe(subscription)
                        self.unsubscribeAlert = false
                    }
                ),
                secondaryButton: .cancel()
            )
        }
    }
}

struct SubscriptionItemRowView: View {
    @ObservedObject var subscription: Subscription
    let summary: Store.SubscriptionSummary?

    var body: some View {
        // Three lines, most-identifying first: a long hostname used to consume the whole headline
        // and truncate away the topic, so "claude-log" and "claude-operator" were indistinguishable.
        // Name -> address -> count, each a step down in emphasis.
        // From one aggregate for the whole list. The fallbacks keep previews and any caller
        // without a summary working; they are the old per-row faulting path and should stay unused
        // in the list itself.
        let totalNotificationCount = summary?.total ?? subscription.notificationCount()
        let unread = summary?.unread ?? subscription.unreadCount()
        let address = subscription.shortUrlString()
        // Each line is a full-width HStack, so the timestamp and the chevron both resolve against
        // the row's own trailing edge. Nesting the text in its own column instead made the time
        // align to that column's edge, which shifted per row with the badge's width.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if subscription.pinned {
                    PinBadge()
                }
                Text(subscription.shortDisplayName())
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                let lastDateTime = summary.map { s in
                    s.lastTime.map { Notification.shortDateTime(for: Date(timeIntervalSince1970: TimeInterval($0))) }
                } ?? subscription.lastNotification()?.shortDateTime()
                if let lastDateTime = lastDateTime {
                    Text(lastDateTime)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        // The timestamp keeps its full width and the topic name yields instead.
                        // Both texts are compressible and this one is pinned to a single line, so
                        // on a narrow screen or at a large Dynamic Type size SwiftUI would happily
                        // truncate its tail — which is the time, the very thing ntfy#1205 is about.
                        // The name is already `lineLimit(1)` and reads fine truncated; a clipped
                        // clock does not.
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }

            HStack(alignment: .center, spacing: 6) {
                // Monospaced so hostnames stay scannable, middle-truncated so both the server and the
                // topic survive on narrow screens instead of losing the tail.
                Text(address)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("on \(subscription.serverHost())"))
                Spacer(minLength: 8)
                if unread > 0 {
                    UnreadBadge(count: unread)
                }
                // Sits on the middle line, which centres it against the three-line row while
                // keeping it on the same trailing edge as the timestamp above.
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .accessibilityHidden(true) // decorative: the row itself is the control
            }

            HStack(spacing: 0) {
                Text("\(totalNotificationCount) notification\(totalNotificationCount != 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Count pill for unread messages in a topic. Capsule rather than a strict circle so three-digit
/// counts stay legible instead of squashing, matching how iOS badges grow.
struct UnreadBadge: View {
    let count: Int

    // Derived from the app's AccentColor (#317F6F) so the badge stays theme-matched: a lifted tint
    // at the top falling to the accent itself, which reads as a subtle sheen at badge size.
    private static let top = Color(red: 0.29, green: 0.62, blue: 0.53)
    private static let bottom = Color(red: 0.192, green: 0.498, blue: 0.435)

    private var label: String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(
                Capsule().fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Self.top, Self.bottom]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .accessibilityLabel(Text("\(count) unread"))
    }
}

/// Marks a pinned topic ahead of its name: a tilted pin in a warm gradient, the colour iOS uses for
/// pins in Messages and Mail, so it reads as "pinned" at a glance without competing with the green
/// unread badge. Sized from the headline font so it scales with Dynamic Type alongside the name.
struct PinBadge: View {
    static let tint = Color(red: 0.96, green: 0.55, blue: 0.13)
    private static let top = Color(red: 1.0, green: 0.74, blue: 0.25)

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.subheadline.weight(.semibold))
            .rotationEffect(.degrees(45))
            .foregroundColor(Self.tint)
            .overlay(
                LinearGradient(gradient: Gradient(colors: [Self.top, Self.tint]),
                               startPoint: .top, endPoint: .bottom)
                    .mask(
                        Image(systemName: "pin.fill")
                            .font(.subheadline.weight(.semibold))
                            .rotationEffect(.degrees(45))
                    )
            )
            .accessibilityLabel(Text("Pinned"))
    }
}

struct SubscriptionListView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SubscriptionListView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}

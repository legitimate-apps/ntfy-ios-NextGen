import SwiftUI
import UIKit
import StoreKit

struct ReleaseNotes: Identifiable, Equatable {
    let version: String
    let bullets: [String]
    var id: String { version }

    /// The App Store "What's New" text per release (CHANGELOG.md, drafts/whats-new-*.md). Add the new
    /// version's entry when cutting a release; a version without an entry shows no card.
    static let shipped: [ReleaseNotes] = [
        ReleaseNotes(version: "1.17.0", bullets: [
            "A new topic has a \"Send a test notification\" button, so you can see a notification arrive without a computer.",
            "Priority 4 and 5 messages can now break through Focus and the Notification Summary when Time Sensitive notifications are allowed in iOS and Focus settings."
        ]),
        ReleaseNotes(version: "1.16.0", bullets: [
            "On a Mac, notification buttons such as Approve now work right from the banner.",
            "Tapping an action button twice sends it once, and a busy server is retried instead of showing a false failure.",
            "Clearer server hints: topics on ntfy.sh explain that they get no instant banners in this app, adding a topic reminds you where your scripts must send, and the self-hosting and migration guides are one tap away.",
            "Reading or dismissing notifications on a self-hosted topic now helps clear them on your other devices.",
            "Settings → About → Licenses lists the open-source software the app is built on."
        ])
    ]
}

enum LaunchExperiencePolicy {
    /// Treat omitted trailing components as zero (1.17 and 1.17.0 are the same).
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    struct Update: Equatable {
        let entries: [ReleaseNotes]
        let recordNow: Bool
    }

    static func update(current: String, lastSeen: String?, hasSubscriptions: Bool,
                       entries: [ReleaseNotes] = ReleaseNotes.shipped) -> Update {
        if let lastSeen, !isNewer(current, than: lastSeen) {
            return Update(entries: [], recordNow: false)
        }
        let eligible = entries.filter { entry in
            guard !isNewer(entry.version, than: current) else { return false }
            if let lastSeen { return isNewer(entry.version, than: lastSeen) }
            // Updating from a release before this card existed: the user never saw any of these notes.
            return hasSubscriptions
        }.sorted { isNewer($0.version, than: $1.version) }
        let selected = Array(eligible.prefix(2))
        return Update(entries: selected, recordNow: selected.isEmpty)
    }

    static func shouldRequestReview(current: String, lastPrompted: String?, topicCount: Int,
                                    totalCount: Int, firstLaunch: Date?, hasSubscriptions: Bool,
                                    now: Date, noticeShown: Bool, foregroundActive: Bool) -> Bool {
        let oldEnough = firstLaunch.map { now.timeIntervalSince($0) >= 2 * 24 * 60 * 60 }
            ?? hasSubscriptions
        return topicCount > 0 && totalCount >= 3 && lastPrompted != current
            && oldEnough && !noticeShown && foregroundActive
    }
}

/// One process session owns notice suppression, even after returning from a topic or switching tabs.
final class LaunchExperience: ObservableObject {
    static let shared = LaunchExperience()
    static let seenKey = "whatsNewLastSeenVersion"
    static let reviewKey = "reviewLastPromptedVersion"
    static let firstLaunchKey = "reviewFirstLaunchDate"
    let current: String
    @Published var showingWhatsNew = false
    private(set) var entries: [ReleaseNotes] = []
    private(set) var noticeShown = false
    private var prepared = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.defaults = defaults
        self.current = current
        #if DEBUG
        // Simulator evidence can seed an update and elapsed install age without changing Info.plist.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-ntfyDebugLastSeenVersion"), i + 1 < arguments.count {
            defaults.set(arguments[i + 1], forKey: Self.seenKey)
        }
        if let i = arguments.firstIndex(of: "-ntfyDebugFirstLaunchDays"), i + 1 < arguments.count,
           let days = Double(arguments[i + 1]) {
            defaults.set(Date().addingTimeInterval(-days * 86400), forKey: Self.firstLaunchKey)
        }
        #endif
    }

    func prepare(hasSubscriptions: Bool, movedTopicsPending: Bool, now: Date = Date()) {
        if movedTopicsPending { noticeShown = true }
        guard !prepared else { return }
        prepared = true
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            // Existing users should not have to wait another two days for this new feature.
            defaults.set(hasSubscriptions ? now.addingTimeInterval(-2 * 24 * 60 * 60) : now,
                         forKey: Self.firstLaunchKey)
        }
        let update = LaunchExperiencePolicy.update(current: current,
            lastSeen: defaults.string(forKey: Self.seenKey), hasSubscriptions: hasSubscriptions)
        entries = update.entries
        if update.recordNow { defaults.set(current, forKey: Self.seenKey) }
    }

    func presentWhatsNew() {
        guard !entries.isEmpty else { return }
        noticeShown = true
        showingWhatsNew = true
    }

    func dismissWhatsNew() {
        defaults.set(current, forKey: Self.seenKey)
        entries = []
    }

    @MainActor
    func requestReview(store: Store, subscription: Subscription) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            window.rootViewController?.presentedViewController == nil else { return }
        let summaries = store.subscriptionSummaries() ?? [:]
        guard LaunchExperiencePolicy.shouldRequestReview(current: current,
            lastPrompted: defaults.string(forKey: Self.reviewKey),
            topicCount: summaries[subscription.objectID]?.total ?? 0,
            totalCount: summaries.values.reduce(0) { $0 + $1.total },
            firstLaunch: defaults.object(forKey: Self.firstLaunchKey) as? Date,
            hasSubscriptions: !(store.getSubscriptions() ?? []).isEmpty,
            now: Date(), noticeShown: noticeShown, foregroundActive: scene.activationState == .foregroundActive)
        else { return }
        defaults.set(current, forKey: Self.reviewKey)
        Log.d("LaunchExperience", "Requesting App Store review for version \(current)")
        if #available(iOS 16.0, *) { AppStore.requestReview(in: scene) }
        else { SKStoreReviewController.requestReview(in: scene) }
    }
}

struct WhatsNewView: View {
    let entries: [ReleaseNotes]
    let onContinue: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.version).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(entry.bullets, id: \.self) { bullet in
                                HStack(alignment: .top) {
                                    Text("•")
                                    Text(bullet).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Button("Continue", action: onContinue)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(Color.accentColor.cornerRadius(10))
                }
                .padding()
            }
            .navigationTitle("What's new")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

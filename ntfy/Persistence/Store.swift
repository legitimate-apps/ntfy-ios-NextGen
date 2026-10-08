import Foundation
import CoreData
import Combine

/// Handles all persistence in the app by storing/loading subscriptions and notifications using Core Data.
/// There are sadly a lot of hacks in here, because I don't quite understand this fully.
class Store: ObservableObject {
    private enum Constants {
        static let kilobyte: Int64 = 1024
        static let megabyte = kilobyte * 1024

        static let autoDownloadNever: Int64 = 0
        static let autoDownloadAlways: Int64 = 1
        static let autoDownload100KB = 100 * kilobyte
        static let autoDownload500KB = 500 * kilobyte
        static let autoDownloadDefault = megabyte
        static let autoDownload5MB = 5 * megabyte
        static let autoDownload10MB = 10 * megabyte
        static let autoDownload50MB = 50 * megabyte
    }

    // Under unit tests the app runs only as the test host and has no active App
    // Group entitlement, so the shared container URL is nil — use the in-memory
    // store to avoid crashing at launch. XCTestCase is only present during test
    // runs, so shipped builds are unaffected and still use the shared container.
    static let shared = Store(inMemory: NSClassFromString("XCTestCase") != nil)
    static let tag = "Store"
    static let appGroup = Config.appGroupId // APP_GROUP_ID, shared by the ntfy and ntfyNSE targets
    static let modelName = "ntfy" // Must match .xdatamodeld folder
    /// Core Data keeps registered entity descriptions alive for the process lifetime. Loading the
    /// compiled model again for every Store therefore leaves several descriptions registered for
    /// each generated NSManagedObject subclass, at which point `User.entity()` and friends can no
    /// longer choose one. Keep exactly one model object per app/NSE/test-host process and inject it
    /// into every persistent container.
    private static let managedObjectModel: NSManagedObjectModel = {
        guard
            let modelURL = Bundle.main.url(forResource: modelName, withExtension: "momd"),
            let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            fatalError("Unable to load Core Data model \(modelName).momd")
        }
        return model
    }()
    static let prefKeyDefaultBaseUrl = "defaultBaseUrl"
    static let prefKeyAttachmentAutoDownloadMaxSize = "attachmentAutoDownloadMaxSize"
    static let prefKeyCriticalAlertsEnabled = "criticalAlertsEnabled"
    static let prefKeyTopicSortOrder = "topicSortOrder"
    static let autoDownloadNever = Constants.autoDownloadNever
    static let autoDownloadAlways = Constants.autoDownloadAlways
    static let autoDownload100KB = Constants.autoDownload100KB
    static let autoDownload500KB = Constants.autoDownload500KB
    static let autoDownloadDefault = Constants.autoDownloadDefault
    static let autoDownload5MB = Constants.autoDownload5MB
    static let autoDownload10MB = Constants.autoDownload10MB
    static let autoDownload50MB = Constants.autoDownload50MB
    private static let sharedDefaults = UserDefaults(suiteName: Store.appGroup)!
    private static let sharedDefaultsKeyCriticalAlertsAuthorized = "criticalAlertsAuthorized"
    private let container: NSPersistentContainer
    /// Injected so credential and migration behavior can be tested without pretending an unsigned
    /// XCTest host can use the Keychain. Production and the NSE use the real implementation.
    var credentialStore: CredentialStoring
    /// Per-topic end-to-end encryption passwords and keys. Injected for the same reason as
    /// `credentialStore`.
    var topicSecrets: TopicSecretStoring
    /// Only local read actions call this; remote ingestion never publishes.
    var clearPublisher: (ClearRequest, @escaping () -> Void) -> Void = { ApiService.shared.clear($0, completion: $1) }
    var notificationRemover: (SequenceRemoval) -> Void = { $0.removeDelivered() }
    /// Whether a missing cached key may be re-derived from the password (PBKDF2). Off in the
    /// notification service extension, which has a tight time and memory budget; the app derives it
    /// the next time it reads the topic, and `retryLockedMessages` then opens what arrived meanwhile.
    var allowsKeyDerivation = !Bundle.main.bundlePath.hasSuffix(".appex")
    var context: NSManagedObjectContext {
        return container.viewContext
    }
    private var cancellables: Set<AnyCancellable> = []
    /// Confined to the context queue; identifies the event deferred by this ingestion.
    private var deferredPushID: String?

    static func persistentStoreURL(
        inMemory: Bool,
        appGroupContainerURL: URL?,
        fallbackApplicationSupportURL: URL
    ) -> URL {
        if inMemory {
            return URL(fileURLWithPath: "/dev/null")
        }
        return (appGroupContainerURL ?? fallbackApplicationSupportURL)
            .appendingPathComponent("ntfy.sqlite")
    }

    init(
        inMemory: Bool = false,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        topicSecrets: TopicSecretStoring = KeychainCredentialStore.shared
    ) {
        self.credentialStore = credentialStore
        self.topicSecrets = topicSecrets
        let fileManager = FileManager.default
        let appGroupContainerURL = inMemory
            ? nil
            : fileManager.containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)
        let fallbackApplicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory.appendingPathComponent("ntfy-application-support", isDirectory: true)
        let storeUrl = Store.persistentStoreURL(
            inMemory: inMemory,
            appGroupContainerURL: appGroupContainerURL,
            fallbackApplicationSupportURL: fallbackApplicationSupportURL
        )
        if !inMemory && appGroupContainerURL == nil {
            NSLog("ntfy: App Group container is unavailable; using process-local persistence. Check the provisioning profile.")
            Log.e(
                Store.tag,
                "App Group container \(Store.appGroup) is unavailable; using process-local persistence at \(storeUrl.path). Check the provisioning profile."
            )
            try? fileManager.createDirectory(
                at: fallbackApplicationSupportURL,
                withIntermediateDirectories: true
            )
        }
        let description = NSPersistentStoreDescription(url: storeUrl)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true

        // Set up container and observe changes from app extension
        container = NSPersistentContainer(
            name: Store.modelName,
            managedObjectModel: Store.managedObjectModel
        )
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { description, error in
            if let error = error {
                Log.e(Store.tag, "Core Data failed to load: \(error.localizedDescription)", error)
            }
        }
        
        // Shortcut for context
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType) // https://stackoverflow.com/a/60362945/1440785
        context.transactionAuthor = Bundle.main.bundlePath.hasSuffix(".appex") ? "ntfy.appex" : "ntfy"
        
        // When a remote change comes in (= the app extension updated entities in Core Data),
        // refresh what the view context already knows about and then tell the observables to
        // re-run their fetches — see `didChangeRemotely` for why the refresh alone is not enough.
        NotificationCenter.default
          .publisher(for: .NSPersistentStoreRemoteChange)
          // Coalesce bursts. Each extension save emits its own remote-change notification, and every
          // one of them costs a full refresh plus a re-fetch in each observable, on the main queue —
          // so twenty pushes landing together would otherwise mean twenty passes over a large
          // history while the user is looking at it. `throttle` delivers the first immediately (the
          // common case is a single message, which must feel instant) and then at most one per
          // window, keeping the latest. Delivery is on main, so the sink body needs no further hop.
          .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
          .sink { value in
              Log.d(Store.tag, "Remote change detected, refreshing views", value)
              self.hardRefresh()
              NotificationCenter.default.post(name: Store.didChangeRemotely, object: nil)
          }
          .store(in: &cancellables)
    }

    /// Broadcast after the app has absorbed a write made by the notification service extension's
    /// process.
    ///
    /// `hardRefresh()` on its own is not enough, which is why a push arriving while the app was
    /// open used to leave the screen stale: `refreshAllObjects()` re-faults only objects the view
    /// context has already registered, and a row inserted by the *extension's* process was never
    /// registered here. An `NSFetchedResultsController`'s membership changes only when the context
    /// it observes processes a save, and a cross-process commit never produces one — so the topic
    /// list showed no new badge and an open topic showed no new row until the user navigated away
    /// and back or pulled to refresh.
    ///
    /// Observables re-run `performFetch()` when this fires. It is deliberately coarse (every
    /// observable re-fetches, not just the affected topic): the payload would have to carry the
    /// changed object ids to do better, and a re-fetch on push arrival is cheap next to the
    /// notification itself.
    static let didChangeRemotely = Foundation.Notification.Name("ntfy.storeDidChangeRemotely")

    /// Posted when the topic sort preference changes. Deliberately distinct from
    /// `didChangeRemotely`: no row moved, only presentation order, so only the subscription list
    /// needs to react — borrowing the cross-process signal would make every open topic re-run its
    /// notification fetch for nothing.
    static let topicSortOrderDidChange = Foundation.Notification.Name("ntfy.topicSortOrderDidChange")
    
    func rollbackAndRefresh() {
        // Hack: We refresh all objects, since failing to store a notification usually means
        // that the app extension stored the notification first. This is a way to update the
        // UI properly when it is in the foreground and the app extension stores a notification.
        
        context.rollback()
        hardRefresh()
    }

    func hardRefresh() {
        // `refreshAllObjects` only refreshes objects from which the cache is invalid. With a staleness intervall of -1 the cache never invalidates.
        // We set the `stalenessInterval` to 0 to make sure that changes in the app extension get processed correctly.
        // From: https://www.avanderlee.com/swift/core-data-app-extension-data-sharing/
        
        context.stalenessInterval = 0
        context.refreshAllObjects()
        context.stalenessInterval = -1
    }

    // MARK: Subscriptions
    
    func saveSubscription(baseUrl: String, topic: String) -> Subscription {
        // `context` is the container's viewContext (main-queue concurrency), so the insert and the save
        // must both run on its queue. Doing only the save under `DispatchQueue.main.sync` left the
        // `Subscription(context:)` insert on the caller's thread — which silently lost the row when the
        // caller was a background queue — and deadlocked outright when the caller was already main.
        // `performAndWait` fixes both: it hops to the context's queue and is reentrant-safe from it.
        var subscription: Subscription!
        context.performAndWait {
            subscription = Subscription(context: context)
            subscription.baseUrl = normalizeBaseUrl(baseUrl)
            subscription.topic = topic
            Log.d(Store.tag, "Storing subscription baseUrl=\(subscription.baseUrl ?? "?"), topic=\(topic)")
            do {
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store subscription", error)
            }
        }
        return subscription
    }
    
    func getSubscription(baseUrl: String, topic: String) -> Subscription? {
        try? fetchSubscription(baseUrl: baseUrl, topic: topic)
    }
    
    func getSubscriptions() -> [Subscription]? {
        return try? context.fetch(Subscription.fetchRequest())
    }

    /// Subscriptions FCM has not confirmed a topic binding for (ntfy#1305).
    ///
    /// These are the retry queue: a row lands here when it is first created, and
    /// stays here until `subscribe(toTopic:)` calls back without an error, so a
    /// failed or never-attempted binding is picked up by the next reconcile
    /// instead of being lost.
    func getSubscriptionsPendingFcmSubscribe() -> [Subscription] {
        var result: [Subscription] = []
        context.performAndWait {
            let request = Subscription.fetchRequest()
            request.predicate = NSPredicate(format: "fcmSubscribed == NO OR fcmSubscribed == nil")
            result = (try? context.fetch(request)) ?? []
        }
        return result
    }

    func setFcmSubscribed(_ subscription: Subscription, _ value: Bool) {
        context.performAndWait {
            guard subscription.fcmSubscribed != value else { return }
            subscription.fcmSubscribed = value
            do {
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot update fcmSubscribed", error)
            }
        }
    }

    /// Void every topic binding, e.g. because the FCM registration token rotated.
    ///
    /// FCM binds topics to a token, so a new token means none of the old
    /// bindings exist any more. Marking them stale is what makes the next
    /// reconcile rebuild them — without this the flags would stay true and the
    /// device would silently stop receiving push, which is the original bug.
    // MARK: FCM generation
    //
    // A monotonic counter that orders FCM subscribe confirmations against the events that
    // invalidate them — a token rotation, or a teardown for the same topic.
    //
    // It lives *here*, behind the Core Data context queue, for one specific reason: "is this
    // confirmation still current?" and "write `fcmSubscribed = true`" have to happen in a single
    // critical section. Keeping the counter in the reconciler behind an `NSLock` could not do that
    // — the check and the write were separate steps, so a confirmation could pass the check
    // immediately before an invalidation and land its write immediately after it. Nor could the
    // lock simply be held across the write: that write hops to this queue, while the main queue may
    // be sitting in `lock.lock()` inside `reconcile()`, which is a deadlock. Putting the counter on
    // the same queue as the write makes the pairing atomic for free, with no lock ordering at all.

    private var fcmGenerationValue = 0

    /// The generation a round should capture when it starts.
    func fcmGeneration() -> Int {
        var generation = 0
        context.performAndWait { generation = fcmGenerationValue }
        return generation
    }

    /// Invalidates every confirmation still in flight. Call when something makes existing bindings
    /// untrustworthy: the registration token rotated, or a teardown for a topic just settled.
    @discardableResult
    func bumpFcmGeneration() -> Int {
        var generation = 0
        context.performAndWait {
            fcmGenerationValue &+= 1
            generation = fcmGenerationValue
        }
        return generation
    }

    /// A complete FCM invalidation, as ONE operation on the context queue: bump the generation, run
    /// `resettingAlso` (state that lives outside Core Data, i.e. the poll topic's flag), and mark
    /// every subscription stale.
    ///
    /// It has to be a single critical section. As three separate steps it left a window in which a
    /// *new*-generation round could start, observe the not-yet-reset state — poll flag still true,
    /// rows still confirmed — find nothing to do and finish, after which the reset landed with no
    /// round scheduled to act on it. Because `reconcile` reads the generation through this same
    /// queue before it reads anything else, a round now either captures the old generation (and has
    /// its confirmations rejected) or the new one (and sees fully reset state).
    func invalidateAllFcmSubscriptions(resettingAlso resetOtherState: () -> Void) {
        context.performAndWait {
            fcmGenerationValue &+= 1
            resetOtherState()
            let subscriptions = (try? context.fetch(Subscription.fetchRequest())) ?? []
            guard !subscriptions.isEmpty else { return }
            subscriptions.forEach { $0.fcmSubscribed = false }
            do {
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot mark FCM subscriptions stale", error)
            }
        }
    }

    /// Runs `body` only if `generation` is still current, atomically with respect to
    /// `bumpFcmGeneration`. Returns whether it ran.
    ///
    /// `body` is where a round commits its confirmation — either `setFcmSubscribed` (which
    /// re-enters this queue harmlessly, `performAndWait` being reentrant) or the poll topic's
    /// defaults write. Both are gated by the same check, in the same critical section as the bump.
    @discardableResult
    func withCurrentFcmGeneration(_ generation: Int, _ body: () -> Void) -> Bool {
        var ran = false
        context.performAndWait {
            guard generation == fcmGenerationValue else { return }
            body()
            ran = true
        }
        return ran
    }

    /// Marks the subscription behind an FCM topic name as needing a fresh bind, by name rather than
    /// by object so the caller can be on any thread. Returns whether a matching subscription exists
    /// — i.e. whether the topic is one the user still wants bound.
    @discardableResult
    func markFcmSubscriptionStale(firebaseTopicName: String) -> Bool {
        var found = false
        context.performAndWait {
            let subscriptions = (try? context.fetch(Subscription.fetchRequest())) ?? []
            guard let match = subscriptions.first(where: { subscription in
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return false }
                return firebaseTopic(baseUrl: baseUrl, topic: topic) == firebaseTopicName
            }) else { return }
            guard match.fcmSubscribed else {
                found = true // already stale — nothing to write, and the caller's rebuild still applies
                return
            }
            match.fcmSubscribed = false
            do {
                try context.save()
                found = true
            } catch let error {
                // Deliberately NOT reported as found. The row still reads subscribed, so the
                // rebuild round would skip it — claiming it was queued would be a lie, and the
                // caller reconciles regardless. A later invalidation retries.
                Log.e(Store.tag, "Cannot mark FCM subscription stale; it stays confirmed for now", error)
                rollbackAndRefresh()
            }
        }
        return found
    }

    /// Resolves a subscription's display name on the context's own queue and returns a plain `String`.
    /// `context` is the main-queue viewContext, so the push path — the NSE's `handleMessage` and
    /// `AppDelegate.showNotification`, both off the main queue — must not fetch a `Subscription` and read
    /// its properties directly (`getSubscription(...)?.displayName()` did exactly that). Doing the fetch
    /// and the `displayName()` extraction inside `performAndWait` keeps every Core Data access on the
    /// context's queue and hands the caller a value it can use from anywhere. Mirrors `getBasicUser`.
    func subscriptionDisplayName(baseUrl: String, topic: String) -> String? {
        var displayName: String?
        context.performAndWait {
            displayName = try? fetchSubscription(baseUrl: baseUrl, topic: topic)?.displayName()
        }
        return displayName
    }

    func completeAttachmentDownload(notificationID: String, localPath: String, resolvedType: String?, resolvedSize: Int64) {
        context.performAndWait {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id = %@", notificationID)
            guard let notification = try? context.fetch(request).first else {
                return
            }

            notification.attachmentLocalPath = localPath
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
            if resolvedSize > 0 {
                notification.attachmentSize = resolvedSize
            }
            if let resolvedType, !resolvedType.isEmpty {
                notification.attachmentType = resolvedType
            }
            try? context.save()
        }
    }

    /// Deletes a subscription and reports whether the delete actually reached the store.
    ///
    /// The caller uses the result to decide whether to tear down the FCM binding, and the two must
    /// not disagree. Swallowing the save error meant a failed delete (disk full, SQLite trouble)
    /// still looked successful, the teardown went out anyway, and the row came back on the next
    /// refresh or relaunch — a subscription the user can still see, whose push is silently dead,
    /// and whose `fcmSubscribed` still reads true so reconciliation skips rebuilding it.
    @discardableResult
    func delete(subscription: Subscription) -> Bool {
        var deleted = false
        context.performAndWait {
            // Capture plain paths — not the managed objects — before deleting, and unlink only
            // after the save commits.
            //
            // Unlinking first would leave the rows a failed save rolls back pointing at files that
            // are already gone. But holding the `Notification` objects instead is its own bug: after
            // the cascade delete they no longer represent rows, so reading `attachmentLocalPath`
            // can fail to fulfil a deleted fault (leaking the file) and writing it back to nil is an
            // unsaved mutation of a deleted object. Strings survive the delete; managed objects
            // don't. Filesystem cleanup is not transactional either way, so it follows the commit.
            var pendingFileCleanup: [String] = []
            if let notifications = subscription.notifications {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification,
                          let localPath = notification.attachmentLocalPath,
                          !localPath.isEmpty else { return }
                    pendingFileCleanup.append(localPath)
                }
            }
            let subscriptionTopicUrl = subscription.baseUrl.flatMap { baseUrl in
                subscription.topic.map { topicUrl(baseUrl: baseUrl, topic: $0) }
            }
            context.delete(subscription)
            do {
                try context.save()
                deleted = true
                // The password belongs to this subscription. A failed delete doesn't block the
                // unsubscribe: the `encrypted` flag goes with the row, nothing reads secrets for an
                // unflagged topic, and setting a password again overwrites it, so a re-subscribe can't
                // revive it.
                if let subscriptionTopicUrl, !topicSecrets.deleteTopicSecret(topicUrl: subscriptionTopicUrl) {
                    Log.w(Store.tag, "Cannot delete the encryption password for \(subscriptionTopicUrl)")
                }
                pendingFileCleanup.forEach {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: $0))
                }
            } catch let error {
                Log.w(Store.tag, "Cannot delete subscription", error)
                rollbackAndRefresh()
            }
        }
        return deleted
    }

    func updateSubscription(subscription: Subscription, displayName: String?) {
        context.performAndWait {
            let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            subscription.customDisplayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try? context.save()
        }
    }

    /// Pinned topics sort above the rest of the subscription list. A Core Data attribute rather
    /// than a preference so the pin lives and dies with the subscription: unsubscribing drops it,
    /// and re-subscribing later starts unpinned instead of resurrecting a stale choice.
    func setPinned(_ pinned: Bool, forSubscription subscription: Subscription) {
        context.performAndWait {
            guard subscription.pinned != pinned else { return }
            subscription.pinned = pinned
            try? context.save()
        }
    }

    // MARK: Read state

    /// Mark every notification in a subscription read (or unread) in one pass. Used by the
    /// subscription list's swipe action and by opening a topic.
    func setRead(_ read: Bool, forSubscription subscription: Subscription) {
        context.performAndWait {
            let request: NSFetchRequest<Notification> = Notification.fetchRequest()
            request.predicate = NSPredicate(
                format: "subscription == %@ AND read != %@", subscription, NSNumber(value: read)
            )
            guard let notifications = try? context.fetch(request), !notifications.isEmpty else {
                return // don't churn the context or bump observers for a no-op
            }
            let clears = read ? notifications.compactMap { clearRequest(for: $0) } : []
            for notification in notifications {
                notification.read = read
            }
            do {
                try context.save()
                clears.forEach { sendClear($0) }
            } catch {
                Log.w(Store.tag, "Cannot mark notifications read", error)
                rollbackAndRefresh()
            }
        }
    }

    /// Marking a topic unread flags only its most recent notification, the way Mail does. Flipping
    /// the whole topic back would resurrect every message the user had already worked through and
    /// show a badge of, say, 20 for a topic they'd fully read — the badge should mean "one new thing
    /// to look at", not "your history is back".
    func markMostRecentUnread(subscription: Subscription) {
        context.performAndWait {
            guard let newest = subscription.lastNotification(), newest.read else { return }
            newest.read = false
            try? context.save()
        }
    }

    func setRead(_ read: Bool, forNotification notification: Notification, completion: (() -> Void)? = nil) {
        context.performAndWait {
            guard notification.read != read else { completion?(); return }
            let clear = read ? clearRequest(for: notification) : nil
            notification.read = read
            do {
                try context.save()
                if let clear { sendClear(clear, completion: completion) }
                else { completion?() }
            } catch {
                Log.w(Store.tag, "Cannot mark notification read", error)
                rollbackAndRefresh()
                completion?()
            }
        }
    }

    /// A tapped/dismissed banner may predate an update to the row. Resolve by sequence, not id.
    func read(message: Message, baseUrl: String, completion: @escaping () -> Void = {}) {
        context.performAndWait {
            guard message.event == "message",
                  let subscription = try? fetchSubscription(baseUrl: baseUrl, topic: message.topic) else { completion(); return }
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "subscription == %@ AND (sequenceID == %@ OR (sequenceID == nil AND id == %@))", subscription, message.sequence, message.sequence)
            guard let notifications = try? context.fetch(request) else { completion(); return }
            let group = DispatchGroup()
            for notification in notifications {
                group.enter()
                setRead(true, forNotification: notification) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }
    }

    /// Called by both alert delivery paths, including a full-order reconciliation.
    func recordPresentation(message: Message, baseUrl: String) {
        context.performAndWait {
            if let subscription = try? fetchSubscription(baseUrl: baseUrl, topic: message.topic) {
                markPresented(id: message.id, on: subscription)
            }
        }
    }

    private func markPresented(id: String, on subscription: Subscription) {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@ AND id == %@", subscription, id)
        if let row = try? context.fetch(request).first {
            row.presented = true
            try? context.save()
        }
    }

    private func clearRequest(for notification: Notification) -> ClearRequest? {
        guard let subscription = notification.subscription, let baseUrl = subscription.baseUrl,
              let topic = subscription.topic, let id = notification.id else { return nil }
        return ClearRequest(baseUrl: baseUrl, topic: topic, sequence: notification.sequenceID ?? id,
                            user: try? fetchUser(baseUrl: baseUrl)?.toBasicUser(credentialStore: credentialStore))
    }

    private func sendClear(_ request: ClearRequest, completion: (() -> Void)? = nil) {
        notificationRemover(SequenceRemoval(baseUrl: request.baseUrl, topic: request.topic, sequence: request.sequence))
        clearPublisher(request) { completion?() }
    }

    /// Unread count resolved on the context's own queue, so the push path can call it safely.
    /// Mirrors `subscriptionDisplayName(baseUrl:topic:)` — see the 2026-07-23 audit note about
    /// returning a value rather than a viewContext-owned managed object.
    func unreadCount(baseUrl: String, topic: String) -> Int {
        var count = 0
        context.performAndWait {
            guard let subscription = try? fetchSubscription(baseUrl: baseUrl, topic: topic) else { return }
            count = subscription.unreadCount()
        }
        return count
    }

    /// Unread notifications across every subscription — what the app icon badge shows.
    ///
    /// A count fetch rather than summing `Subscription.unreadCount()` over the subscription list:
    /// it resolves in SQLite instead of faulting in every notification, and because it goes to the
    /// store it also sees rows the notification service extension wrote from its own process while
    /// the app was backgrounded.
    func totalUnreadCount() -> Int {
        var count = 0
        context.performAndWait {
            let request: NSFetchRequest<Notification> = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "read == NO")
            do {
                count = try context.count(for: request)
            } catch {
                Log.w(Store.tag, "Cannot count unread notifications", error)
            }
        }
        return count
    }


    // MARK: Notifications
    
    func save(notificationFromMessage message: Message, withSubscription subscription: Subscription) {
        save(notificationsFromMessages: [message], withSubscription: subscription)
    }

    /// Persists a single pushed message. Returns whether the extension should go on to build and
    /// deliver rich content for it.
    ///
    /// Deliberately does NOT report "this id was already stored" as a reason to suppress delivery,
    /// even though `saveNotifications` knows it. Two things make "a row exists" a bad proxy for
    /// "the user was already alerted":
    ///   1. `SubscriptionManager.subscribe` polls with `since=all` through the completion-discarding
    ///      `poll(_:)` overload, so the server's whole cached history lands in the store with no
    ///      banner ever shown. A genuinely new message published during that window can be stored
    ///      by the poll first — suppressing its push would erase the user's only notification of it.
    ///   2. The `Notification` uniqueness constraint is `id` alone, unscoped by subscription, so two
    ///      independent servers that mint the same id collide — and the second server's genuinely
    ///      different message would be suppressed as a "duplicate".
    /// Doing this properly needs a durable per-notification "was alerted" flag and a subscription-
    /// scoped uniqueness constraint, i.e. a new model version. Until then, an occasional re-alert on
    /// an FCM redelivery is strictly better than a dropped first banner.
    func save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> Bool {
        return ingest(pushedMessage: message, baseUrl: baseUrl, topic: topic) != nil
    }

    /// `save(notificationFromMessage:baseUrl:topic:)` for the push path: returns the message as it was
    /// stored — decrypted, or the "Encrypted message" placeholder, for an end-to-end encrypted topic —
    /// so the banner shows what the row shows. Nil when the subscription is unknown or the save failed.
    func ingest(pushedMessage message: Message, baseUrl: String, topic: String) -> PushedMessageResult? {
        var stored: PushedMessageResult?
        context.performAndWait {
            do {
                // The extension can stay alive across pushes and never hard-refreshes, so its copy of
                // the row may predate a password set in the app since. Re-read it from the store.
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                refreshFromStore(subscription)
                let ingested = ingest([message], for: subscription)
                if let item = ingested.first, let iv = item.iv,
                   isReplay(iv: iv, id: item.message.id, on: subscription) {
                    Log.w(Store.tag, "Dropping a replayed encrypted message (\(item.message.id))")
                    stored = .replay
                    return
                }
                let changed = try saveNotifications(ingested, withSubscription: subscription, isPush: true)
                if let updated = changed.first {
                    markPresented(id: updated.id, on: subscription)
                    stored = .stored(updated)
                } else if deferredPushID == message.id, let request = pollRequest(for: subscription) {
                    stored = .reconcile(request)
                } else if message.isControl {
                    stored = .handled
                } else if let item = ingested.first, message.event == "message" {
                    // Preserve first-banner delivery for a message already inserted by a foreground
                    // poll, but never re-alert an obsolete version of a sequence.
                    let request = Notification.fetchRequest()
                    request.predicate = NSPredicate(format: "subscription == %@ AND id == %@", subscription, message.id)
                    if let row = try context.fetch(request).first {
                        var presentation = item.message
                        presentation.isUpdate = row.read || row.presented
                        markPresented(id: row.id ?? "", on: subscription)
                        stored = .stored(presentation)
                    } else {
                        stored = .handled
                    }
                } else {
                    stored = .handled
                }
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return stored
    }

    /// Stores `messages` and returns only the ones that were actually inserted, i.e. the messages the
    /// user has not been notified about yet. Callers that alert the user (the background `~poll`
    /// wakeup) must notify for the returned messages, never for the raw server response — overlapping
    /// polls share a `since` cursor and routinely re-deliver already-stored messages.
    @discardableResult
    func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) -> [Message] {
        guard !messages.isEmpty else { return [] }

        var newMessages: [Message] = []
        context.performAndWait {
            do {
                newMessages = try saveNotifications(ingest(messages, for: subscription), withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return newMessages
    }
    
    /// Snapshots what a poll of `subscription` needs, on the context's queue. Nil when the
    /// subscription is gone (deleted, or a dead row without a base URL).
    func pollRequest(for subscription: Subscription) -> PollRequest? {
        var request: PollRequest?
        context.performAndWait {
            guard !subscription.isDeleted, subscription.managedObjectContext != nil,
                  let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return }
            request = PollRequest(
                subscriptionID: subscription.objectID,
                baseUrl: baseUrl,
                topicUrl: topicUrl(baseUrl: baseUrl, topic: topic),
                since: subscription.sequenceReconcile ? nil : subscription.lastNotificationId,
                user: try? fetchUser(baseUrl: baseUrl)?.toBasicUser(credentialStore: credentialStore)
            )
        }
        return request
    }

    /// Stores a poll response against the subscription the request was made for, re-resolved by
    /// object ID on the context's queue. Returns the newly inserted messages, or nil (nothing saved)
    /// when that subscription no longer exists — it was unsubscribed while the request was out.
    func save(notificationsFromMessages messages: [Message], polledWith request: PollRequest) -> [Message]? {
        var newMessages: [Message]?
        context.performAndWait {
            guard let subscription = try? context.existingObject(with: request.subscriptionID) as? Subscription,
                  !subscription.isDeleted else {
                Log.d(Store.tag, "Dropping a poll response for \(request.topicUrl): unsubscribed meanwhile")
                return
            }
            guard !messages.isEmpty else {
                newMessages = []
                return
            }
            do {
                newMessages = try saveNotifications(ingest(messages, for: subscription), withSubscription: subscription, polledSince: request.since)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
                newMessages = []
            }
        }
        return newMessages
    }

    func delete(notification: Notification) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting notification \(notification.id ?? "")")
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
            try? context.save()
        }
    }
    
    func delete(notifications: Set<Notification>) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting \(notifications.count) notification(s)")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
    
    func delete(allNotificationsFor subscription: Subscription) {
        context.performAndWait {
            guard let notifications = subscription.notifications else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) for subscription \(subscription.urlString())")
            do {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
    
    // MARK: End-to-end encryption

    /// `Subscription.encrypted` is the source of truth for whether a topic has a password; the
    /// Keychain only holds the secret. A flagged topic whose key can't be read right now (before first
    /// unlock, a transient Keychain error, a lost item) fails closed: encrypted messages arrive locked
    /// and plaintext is marked "Not encrypted", never shown as ordinary.
    ///
    /// No mapping from unflagged topics with a stored secret: the flag and the feature ship together,
    /// so only pre-release builds of this branch could hold such a secret, and reading the Keychain
    /// for every unencrypted topic to find one would cost every user a lookup per batch.
    func topicKeyState(for subscription: Subscription) -> TopicKeyState {
        guard subscription.encrypted else { return .notEncrypted }
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return .unavailable }
        let url = topicUrl(baseUrl: baseUrl, topic: topic)
        switch topicSecrets.topicKey(topicUrl: url) {
        case .found(let key) where key.count == TopicEncryption.keyLength:
            return .key(key)
        case .failed:
            return .unavailable
        case .found, .notFound:
            break // Missing or malformed cache: re-derive from the password if we may.
        }
        guard allowsKeyDerivation,
              case .found(let password) = topicSecrets.topicPassword(topicUrl: url),
              let key = TopicEncryption.deriveKey(password: password, topicUrl: url) else {
            return .unavailable
        }
        topicSecrets.setTopicSecret(password: password, key: key, topicUrl: url)
        return .key(key)
    }

    func encryptionKeyState(baseUrl: String, topic: String) -> TopicKeyState {
        var state = TopicKeyState.notEncrypted
        context.performAndWait {
            if let subscription = try? fetchSubscription(baseUrl: baseUrl, topic: topic) {
                state = topicKeyState(for: subscription)
            }
        }
        return state
    }

    /// The key for an encrypted topic whose key is readable now; nil otherwise.
    func encryptionKey(baseUrl: String, topic: String) -> Data? {
        encryptionKeyState(baseUrl: baseUrl, topic: topic).key
    }

    /// What the encryption settings screen shows. Reads the Keychain only for flagged topics.
    func encryptionPasswordState(for subscription: Subscription) -> TopicPasswordState {
        guard subscription.encrypted else { return .off }
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return .unreadable }
        if case .found(let password) = topicSecrets.topicPassword(topicUrl: topicUrl(baseUrl: baseUrl, topic: topic)) {
            return .on(password)
        }
        return .unreadable
    }

    /// Sets (or changes) a topic's password, then opens any of its messages that arrived while they
    /// could not be read. Returns how many were opened, or nil when nothing changed.
    ///
    /// Order: Keychain first, then the flag. If the Keychain write fails the flag is untouched (still
    /// off, or still on with the old password). If the flag can't be saved after a successful write,
    /// a topic that was off stays off and its new secret is never read.
    @discardableResult
    func setEncryptionPassword(_ typed: String, for subscription: Subscription) -> Int? {
        let password = TopicEncryption.normalizedPassword(typed)
        guard !password.isEmpty, let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
        let url = topicUrl(baseUrl: baseUrl, topic: topic)
        guard let key = TopicEncryption.deriveKey(password: password, topicUrl: url),
              topicSecrets.setTopicSecret(password: password, key: key, topicUrl: url) else {
            Log.w(Store.tag, "Cannot store the encryption password for \(url)")
            return nil
        }
        guard setEncryptedFlag(true, for: subscription) else { return nil }
        return retryDecryption(for: subscription, key: key)
    }

    /// Removes a topic's password. Messages already decrypted stay readable; new encrypted ones arrive
    /// locked. Returns false, with the topic still flagged, when either step fails.
    ///
    /// Order: Keychain first, then the flag. A failed delete leaves everything as it was. A failed flag
    /// save after a successful delete leaves the topic flagged with no key, which fails closed (locked
    /// and "Not encrypted" markers) and shows as on-but-unreadable in settings, where removing again works.
    @discardableResult
    func removeEncryptionPassword(for subscription: Subscription) -> Bool {
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return false }
        guard topicSecrets.deleteTopicSecret(topicUrl: topicUrl(baseUrl: baseUrl, topic: topic)) else {
            Log.w(Store.tag, "Cannot delete the encryption password for \(topic)")
            return false
        }
        return setEncryptedFlag(false, for: subscription)
    }

    private func setEncryptedFlag(_ encrypted: Bool, for subscription: Subscription) -> Bool {
        var saved = false
        context.performAndWait {
            guard subscription.encrypted != encrypted else { saved = true; return }
            subscription.encrypted = encrypted
            do {
                try context.save()
                saved = true
            } catch let error {
                Log.w(Store.tag, "Cannot save the topic's encryption setting", error)
                rollbackAndRefresh()
            }
        }
        return saved
    }

    /// Opens locked messages on flagged topics whose key has become readable (after first unlock, after
    /// a transient Keychain error, or once the app re-derived a key the extension couldn't). Cheap when
    /// there is nothing to do: one Core Data count per flagged topic, and a Keychain read only for
    /// topics that have locked messages.
    @discardableResult
    func retryLockedMessages() -> Int {
        var opened = 0
        context.performAndWait {
            let request = Subscription.fetchRequest()
            request.predicate = NSPredicate(format: "encrypted == YES")
            guard let subscriptions = try? context.fetch(request) else { return }
            for subscription in subscriptions where hasLockedMessages(subscription) {
                if case .key(let key) = topicKeyState(for: subscription) {
                    opened += retryDecryption(for: subscription, key: key)
                }
            }
        }
        return opened
    }

    /// Whether `subscription` already stored an authenticated message with this IV under another id.
    private func isReplay(iv: String, id: String, on subscription: Subscription) -> Bool {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@ AND jweIV == %@ AND id != %@", subscription, iv, id)
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    private func hasLockedMessages(_ subscription: Subscription) -> Bool {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(
            format: "subscription == %@ AND encryption == %d",
            subscription, NotificationEncryption.locked.rawValue
        )
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// Decrypts the topic's stored locked messages with `key`. Returns how many opened.
    @discardableResult
    private func retryDecryption(for subscription: Subscription, key: Data) -> Int {
        var opened = 0
        var removed = false
        var openedIVs = Set<String>()
        context.performAndWait {
            guard let topic = subscription.topic else { return }
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(
                format: "subscription == %@ AND encryption == %d",
                subscription, NotificationEncryption.locked.rawValue
            )
            request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)] // keep the earliest copy
            do {
                for notification in try context.fetch(request) {
                    guard let ciphertext = notification.ciphertext, let id = notification.id else { continue }
                    // Only the envelope: everything shown comes from the authenticated payload.
                    let outer = Message(
                        id: id, time: notification.time, event: "message", topic: topic,
                        message: ciphertext
                    )
                    let ingested = TopicEncryption.ingest(outer, key: key)
                    guard ingested.encryption == .decrypted else { continue }
                    if let iv = ingested.iv {
                        // Two locked copies of one ciphertext (an original and its replay): keep one.
                        guard openedIVs.insert(iv).inserted, !isReplay(iv: iv, id: id, on: subscription) else {
                            context.delete(notification)
                            removed = true
                            continue
                        }
                        notification.jweIV = iv
                    }
                    let message = ingested.message
                    notification.message = message.message ?? ""
                    notification.title = message.title ?? ""
                    notification.priority = Store.clampPriority(message.priority)
                    notification.tags = message.tags?.joined(separator: ",") ?? ""
                    notification.actions = Actions.shared.encode(message.actions)
                    notification.click = message.click ?? ""
                    notification.icon = message.icon
                    notification.contentType = message.contentType
                    notification.encryption = NotificationEncryption.decrypted.rawValue
                    notification.ciphertext = nil
                    opened += 1
                }
                if opened > 0 || removed {
                    try context.save()
                }
            } catch let error {
                Log.w(Store.tag, "Cannot retry decryption", error)
                opened = 0
                rollbackAndRefresh()
            }
        }
        return opened
    }

    /// Applies end-to-end decryption to messages arriving for `subscription`. The keychain is only
    /// touched when one of them actually is encrypted.
    /// Unflagged topics never touch the Keychain. Flagged ones read it once per batch, and fail closed
    /// when the key can't be read: encrypted bodies are locked, plaintext is marked.
    private func ingest(_ messages: [Message], for subscription: Subscription) -> [IngestedMessage] {
        let state = subscription.encrypted && messages.contains(where: { $0.event == "message" })
            ? topicKeyState(for: subscription)
            : .notEncrypted
        return messages.map {
            TopicEncryption.ingest($0, key: state.key, topicEncrypted: state != .notEncrypted)
        }
    }

    // MARK: Users
    
    /// Saves a user. A nil password means an existing credential must be left untouched; an empty
    /// non-nil password retains CredentialStoring's explicit delete semantics.
    func saveUser(baseUrl: String, username: String, password: String?) {
        // Same main-queue contract as saveSubscription: the Add-subscription login path calls this from
        // a URLSession completion, so the fetch/insert/save must be hopped onto the context's queue.
        context.performAndWait {
            do {
                let normalized = normalizeBaseUrl(baseUrl)
                let user = getUser(baseUrl: baseUrl) ?? User(context: context)
                user.baseUrl = normalized
                user.username = username
                // The password goes to the Keychain, never to Core Data. The column stays on the
                // entity only so old stores can be migrated and cleared — see
                // migrateCredentialsToKeychain(). It is blanked rather than set to nil because the
                // model declares `password` non-optional: assigning nil fails validation, the save
                // throws, and rollbackAndRefresh() then discards the whole user.
                if let password {
                    user.password = ""
                    _ = credentialStore.setPassword(password, baseUrl: normalized)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store user", error)
                rollbackAndRefresh()
            }
        }
    }

    /// Moves any password still sitting in Core Data into the Keychain and blanks the column.
    /// Idempotent, and safe to call on every launch: users written by a newer build already have a
    /// nil password, so this walks a short list and does nothing.
    @discardableResult
    func migrateCredentialsToKeychain() -> Int {
        var migrated = 0
        context.performAndWait {
            guard let users = try? context.fetch(User.fetchRequest()) as? [User] else { return }
            for user in users {
                guard let baseUrl = user.baseUrl,
                      let legacy = user.password, !legacy.isEmpty else { continue }
                // Only clear Core Data once the Keychain write is confirmed — losing a password
                // would silently break every read-protected topic on that server.
                if credentialStore.setPassword(legacy, baseUrl: baseUrl) {
                    user.password = "" // non-optional in the model; see saveUser
                    migrated += 1
                } else {
                    Log.w(Store.tag, "Keychain write failed for \(baseUrl); leaving the stored password in place")
                }
            }
            if migrated > 0 {
                Log.d(Store.tag, "Migrated \(migrated) password(s) out of Core Data into the Keychain")
                try? context.save()
            }
        }
        return migrated
    }
    
    func getUser(baseUrl: String) -> User? {
        try? fetchUser(baseUrl: baseUrl)
    }

    func getBasicUser(baseUrl: String) -> BasicUser? {
        var basicUser: BasicUser?
        context.performAndWait {
            basicUser = try? fetchUser(baseUrl: baseUrl)?.toBasicUser(credentialStore: credentialStore)
        }
        return basicUser
    }

    func findSubscriptionMatch(forPollRequestTopic topic: String, preferredBaseUrl: String? = nil) -> (baseUrl: String, topic: String)? {
        var match: (baseUrl: String, topic: String)?
        context.performAndWait {
            guard let subscriptions = try? context.fetch(Subscription.fetchRequest()) else {
                Log.w(Store.tag, "\(#function): Can't find subscriptions with topic=\(topic)")
                return
            }
            let normalizedPreferredBaseUrl = preferredBaseUrl.map(normalizeBaseUrl)
            let normalizedDefaultBaseUrl = normalizeBaseUrl(Config.appBaseUrl)
            let matchingSubscriptions = subscriptions.filter {
                $0.urlHash() == topic || $0.topic == topic
            }
            Log.d(
                Store.tag,
                "\(#function) topic=\(topic) matched \(matchingSubscriptions.count) subscription(s)",
                matchingSubscriptions.compactMap { subscription -> String? in
                    guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                        return nil
                    }
                    return topicUrl(baseUrl: baseUrl, topic: topic)
                }
            )

            let prioritizedMatch = matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl else {
                    return false
                }
                if let normalizedPreferredBaseUrl {
                    return normalizeBaseUrl(baseUrl) == normalizedPreferredBaseUrl
                }
                return false
            } ?? matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl, let subscriptionTopic = $0.topic else {
                    return false
                }
                return subscriptionTopic == topic && normalizeBaseUrl(baseUrl) == normalizedDefaultBaseUrl
            } ?? matchingSubscriptions.first

            match = prioritizedMatch.flatMap { subscription in
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                    return nil
                }
                return (baseUrl, topic)
            }
            if match == nil {
                Log.w(
                    Store.tag,
                    "\(#function) No poll request subscription match topic=\(topic) and preferredBaseUrl=\(normalizedPreferredBaseUrl ?? "<nil>")"
                )
            }
        }
        return match
    }
    
    func delete(user: User) {
        context.performAndWait {
            let baseUrl = user.baseUrl
            do {
                context.delete(user)
                try context.save()
                if let baseUrl, !credentialStore.deletePassword(baseUrl: baseUrl) {
                    Log.w(Store.tag, "Deleted user but could not delete its Keychain password for \(baseUrl)")
                }
            } catch let error {
                Log.w(Store.tag, "Cannot delete user", error)
                rollbackAndRefresh()
            }
        }
    }
    
    // MARK: Preferences
    
    func saveDefaultBaseUrl(baseUrl: String?) {
        context.performAndWait {
            do {
                let pref = getPreference(key: Store.prefKeyDefaultBaseUrl) ?? Preference(context: context)
                pref.key = Store.prefKeyDefaultBaseUrl
                pref.value = baseUrl.map(normalizeBaseUrl) ?? Config.appBaseUrl
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store preference", error)
                rollbackAndRefresh()
            }
        }
    }

    func getDefaultBaseUrl() -> String {
        let baseUrl = preferenceValue(key: Store.prefKeyDefaultBaseUrl)
        if baseUrl == nil || baseUrl?.isEmpty == true {
            return Config.appBaseUrl
        }
        return normalizeBaseUrl(baseUrl!)
    }

    func getAttachmentAutoDownloadMaxSize() -> Int64 {
        guard
            let rawValue = preferenceValue(key: Store.prefKeyAttachmentAutoDownloadMaxSize),
            let maxSize = Int64(rawValue)
        else {
            return Store.autoDownloadDefault
        }
        return maxSize
    }

    func saveAttachmentAutoDownloadMaxSize(_ maxSize: Int64) {
        context.performAndWait {
            do {
                let pref = getPreference(key: Store.prefKeyAttachmentAutoDownloadMaxSize) ?? Preference(context: context)
                pref.key = Store.prefKeyAttachmentAutoDownloadMaxSize
                pref.value = String(maxSize)
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store attachment auto-download preference", error)
                rollbackAndRefresh()
            }
        }
    }

    /// How the subscription list is ordered. Stored as a string so an unknown future value falls
    /// back to the default rather than mapping onto the wrong case.
    enum TopicSortOrder: String, CaseIterable {
        /// Alphabetical by the name actually shown in the row, so a renamed topic sorts where the
        /// user sees it — the fetch sorts on the raw `topic`, which after a rename bears no
        /// relation to the visible label and made the order look arbitrary.
        case name
        /// Newest activity first, which is what people ask for on a busy device (ntfy#1740).
        case recentActivity

        static let `default` = TopicSortOrder.name
    }

    func getTopicSortOrder() -> TopicSortOrder {
        guard let raw = preferenceValue(key: Store.prefKeyTopicSortOrder),
              let order = TopicSortOrder(rawValue: raw) else {
            return .default
        }
        return order
    }

    func saveTopicSortOrder(_ order: TopicSortOrder) {
        context.performAndWait {
            do {
                let pref = getPreference(key: Store.prefKeyTopicSortOrder) ?? Preference(context: context)
                pref.key = Store.prefKeyTopicSortOrder
                pref.value = order.rawValue
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store topic sort order", error)
                rollbackAndRefresh()
            }
        }
    }

    /// Writes a raw preference value, so a test can plant something a future build might store and
    /// check that this one falls back rather than mapping it onto the wrong case.
    func saveRawTopicSortOrderForTesting(_ raw: String) {
        context.performAndWait {
            let pref = getPreference(key: Store.prefKeyTopicSortOrder) ?? Preference(context: context)
            pref.key = Store.prefKeyTopicSortOrder
            pref.value = raw
            try? context.save()
        }
    }

    /// Everything a subscription row displays, without touching a single managed object.
    struct SubscriptionSummary {
        let total: Int
        let unread: Int
        /// Nil when the topic has no messages yet, which is distinct from a time of zero.
        let lastTime: Int64?
    }

    /// Row data for every subscription, as TWO aggregate queries for the whole list.
    ///
    /// The row used to ask each subscription directly: `notificationCount()` faults the entire
    /// to-many set, `unreadCount()` faults and reduces it, and `lastNotification()` faults and
    /// *sorts* it — three passes over a topic's whole history, per row, on every render. A user
    /// with a few thousand stored messages paid that on every badge change and every scroll.
    ///
    /// Grouped counts resolve in SQLite instead. Two queries rather than one because the unread
    /// tally needs a predicate the totals must not share.
    func subscriptionSummaries() -> [NSManagedObjectID: SubscriptionSummary]? {
        var totals: [NSManagedObjectID: (count: Int, lastTime: Int64?)] = [:]
        var unreads: [NSManagedObjectID: Int] = [:]
        var failed = false

        context.performAndWait {
            func groupedFetch(predicate: NSPredicate?, includeMaxTime: Bool) -> [NSDictionary]? {
                let request = NSFetchRequest<NSDictionary>(entityName: "Notification")
                request.resultType = .dictionaryResultType
                request.predicate = predicate
                request.propertiesToGroupBy = ["subscription"]

                let count = NSExpressionDescription()
                count.name = "rowCount"
                count.expression = NSExpression(forFunction: "count:",
                                                arguments: [NSExpression(forKeyPath: "time")])
                count.expressionResultType = .integer64AttributeType

                var properties: [Any] = ["subscription", count]
                if includeMaxTime {
                    let maxTime = NSExpressionDescription()
                    maxTime.name = "maxTime"
                    maxTime.expression = NSExpression(forFunction: "max:",
                                                      arguments: [NSExpression(forKeyPath: "time")])
                    maxTime.expressionResultType = .integer64AttributeType
                    properties.append(maxTime)
                }
                request.propertiesToFetch = properties

                do {
                    return try context.fetch(request)
                } catch let error {
                    Log.w(Store.tag, "Cannot aggregate subscription rows", error)
                    return nil
                }
            }

            // A failed query must not read as "every topic is empty" — that would blank the whole
            // list's counts and badges. Report failure and let the caller fall back to the slow but
            // correct per-object path instead.
            guard let totalRows = groupedFetch(predicate: nil, includeMaxTime: true),
                  let unreadRows = groupedFetch(predicate: NSPredicate(format: "read == NO"),
                                                includeMaxTime: false) else {
                failed = true
                return
            }
            for row in totalRows {
                guard let objectID = row["subscription"] as? NSManagedObjectID else { continue }
                totals[objectID] = (row["rowCount"] as? Int ?? 0, row["maxTime"] as? Int64)
            }
            for row in unreadRows {
                guard let objectID = row["subscription"] as? NSManagedObjectID else { continue }
                unreads[objectID] = row["rowCount"] as? Int ?? 0
            }
        }

        guard !failed else { return nil }

        var summaries: [NSManagedObjectID: SubscriptionSummary] = [:]
        for (objectID, total) in totals {
            summaries[objectID] = SubscriptionSummary(total: total.count,
                                                      unread: unreads[objectID] ?? 0,
                                                      lastTime: total.lastTime)
        }
        return summaries
    }

    func getCriticalAlertsEnabled() -> Bool {
        preferenceValue(key: Store.prefKeyCriticalAlertsEnabled) == "true"
    }

    func saveCriticalAlertsEnabled(_ enabled: Bool) {
        context.performAndWait {
            do {
                let pref = getPreference(key: Store.prefKeyCriticalAlertsEnabled) ?? Preference(context: context)
                pref.key = Store.prefKeyCriticalAlertsEnabled
                pref.value = String(enabled)
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store critical alerts preference", error)
                rollbackAndRefresh()
            }
        }
    }

    static func getCriticalAlertsAuthorized() -> Bool {
        sharedDefaults.bool(forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    static func saveCriticalAlertsAuthorized(_ enabled: Bool) {
        sharedDefaults.set(enabled, forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    func shouldAutoDownloadAttachment(_ attachment: MessageAttachment) -> Bool {
        if attachment.isExpired() {
            return false
        }

        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadNever {
            return false
        }
        if maxSize == Store.autoDownloadAlways {
            return true
        }
        guard let size = attachment.size else {
            return true
        }
        return size <= maxSize
    }

    func resolvedAttachmentAutoDownloadMaxSize() -> Int64? {
        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadAlways {
            return nil
        }
        return maxSize
    }
    
    /// Fetches the `Preference` row itself. Callers must already be on the context's queue — every
    /// one of them is a writer that goes on to mutate the returned object, so they wrap the whole
    /// read-modify-save in `performAndWait` themselves. Readers must use `preferenceValue(key:)`.
    private func getPreference(key: String) -> Preference? {
        let request = Preference.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "key = %@", key)])
        return try? context.fetch(request).first
    }

    /// A preference's value, resolved on the context's own queue and returned as a plain `String`.
    ///
    /// The push path reads preferences from queues that are provably not the viewContext's:
    /// `NotificationContent.modify` asks for the critical-alerts flag and `attachImageIfNeeded` asks
    /// for the auto-download policy, and both run on the NSE's delivery queue and on the URLSession
    /// completion queue of the app's `~poll` wakeup. Fetching a main-queue context — and then
    /// reading a property off the returned managed object — from there is a Core Data concurrency
    /// violation. Same shape as `subscriptionDisplayName` and `getBasicUser`: hop, extract a value,
    /// hand back something that is safe to touch anywhere.
    private func preferenceValue(key: String) -> String? {
        var value: String?
        context.performAndWait {
            value = getPreference(key: key)?.value
        }
        return value
    }

    /// Re-reads one object from the store, discarding this context's cached copy. With the context's
    /// `stalenessInterval` of -1 a plain refresh would reuse the cached row, so it is set to 0 for the
    /// refresh (as `hardRefresh` does for every object).
    private func refreshFromStore(_ object: NSManagedObject) {
        let staleness = context.stalenessInterval
        context.stalenessInterval = 0
        context.refresh(object, mergeChanges: false)
        context.stalenessInterval = staleness
    }

    private func fetchSubscription(baseUrl: String, topic: String) throws -> Subscription? {
        let fetchRequest = Subscription.fetchRequest()
        let baseUrlPredicate = NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))
        let topicPredicate = NSPredicate(format: "topic = %@", topic)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [baseUrlPredicate, topicPredicate])
        return try context.fetch(fetchRequest).first
    }

    private func fetchUser(baseUrl: String) throws -> User? {
        let request = User.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))])
        return try context.fetch(request).first
    }

    /// ntfy priorities run 1...5 and the Core Data model enforces that range — but Core Data
    /// validates at *save* time, so one out-of-range value fails the whole batch, the catch rolls
    /// back the `lastNotificationId` advance along with it, and the next poll re-fetches the same
    /// window and fails identically. A topic could stop storing messages permanently, with no error
    /// shown. A stock ntfy server rejects a bad `Priority` header at publish, so this needs a
    /// non-conforming server or an intermediary — but the blast radius is out of all proportion to
    /// a clamp. 0 and nil both mean "not set" and map to ntfy's default of 3.
    static func clampPriority(_ priority: Int16?) -> Int16 {
        guard let priority = priority, priority != 0 else { return 3 }
        return min(5, max(1, priority))
    }

    /// Apply the ordered server stream transactionally. Controls are metadata, never message rows.
    /// Seen event ids and tombstones survive row deletion, preventing overlapping polls from reviving
    /// a deleted version. States belong to the subscription and are cascaded on unsubscribe.
    @discardableResult
    private func saveNotifications(_ ingested: [IngestedMessage], withSubscription subscription: Subscription, polledSince: String? = nil, isPush: Bool = false) throws -> [Message] {
        if isPush { deferredPushID = nil }
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", subscription)
        var rows = try context.fetch(request)
        let stateRequest = NSFetchRequest<NSManagedObject>(entityName: "SequenceState")
        stateRequest.predicate = NSPredicate(format: "subscription == %@", subscription)
        var states: [String: NSManagedObject] = [:]
        for state in try context.fetch(stateRequest) {
            refreshFromStore(state)
            if let sequence = state.value(forKey: "sequenceID") as? String { states[sequence] = state }
        }
        let initialCursor = subscription.lastNotificationId
        let positions = Dictionary(ingested.enumerated().map { ($0.element.message.id, $0.offset) }, uniquingKeysWith: { _, last in last })
        if !isPush { subscription.sequenceReconcile = false }
        var presentations: [Message] = []
        var removals: [SequenceRemoval] = []
        var traversed = Set<String>()
        var batchIVs = Set<String>()

        for item in ingested {
            var message = item.message
            guard message.topic == subscription.topic, message.event == "message" || message.isControl else { continue }
            let sequence = message.sequence
            let row = rows.first { !$0.isDeleted && (($0.sequenceID ?? $0.id) == sequence || $0.id == message.id) }
            let sequenceKey = topicUrl(baseUrl: subscription.baseUrl ?? "", topic: message.topic) + "/" + sequence
            // Backfill identity when the cached original was stored before this model existed.
            if row?.id == message.id {
                row?.sequenceID = message.sequenceID.flatMap { $0.isEmpty ? nil : $0 }
                row?.sequenceKey = sequenceKey
            }
            let state = states[sequence]
            let seen = Set((state?.value(forKey: "seenIDs") as? String ?? "").split(separator: ",").map(String.init))
            let lastID = state?.value(forKey: "eventID") as? String
            let lastTime = state?.value(forKey: "time") as? Int64 ?? row?.time ?? 0
            let lastEvent = state?.value(forKey: "event") as? String
            let orderedAfterState = lastID.map { $0 == polledSince || traversed.contains($0) } == true
                || (!isPush && polledSince != nil && polledSince == initialCursor)
            traversed.insert(message.id)
            guard message.id != lastID, message.time >= lastTime else { continue }
            if seen.contains(message.id) && !orderedAfterState { continue }
            if row?.id == message.id && lastEvent != "message_clear" && lastEvent != "message_delete" { continue }
            if message.time == lastTime, let lastID {
                if let currentPosition = positions[lastID], let position = positions[message.id], position < currentPosition { continue }
                if isPush || (!orderedAfterState && positions[lastID] == nil) {
                    subscription.sequenceReconcile = true
                    if isPush { deferredPushID = message.id }
                    continue
                }
            }
            // APNs can arrive out of order, and seconds do not order two event ids. A tombstone wins
            // an ambiguous same-second push; an ordered poll can explicitly revive the sequence.
            if message.event == "message", message.time == lastTime,
               lastEvent == "message_clear" || lastEvent == "message_delete", !orderedAfterState { continue }
            if message.event == "message", let iv = item.iv {
                guard batchIVs.insert(iv).inserted, !isReplay(iv: iv, id: message.id, on: subscription) else { continue }
            }
            let next = state ?? NSEntityDescription.insertNewObject(forEntityName: "SequenceState", into: context)
            next.setValue(topicUrl(baseUrl: subscription.baseUrl ?? "", topic: message.topic) + "/" + sequence, forKey: "key")
            next.setValue(subscription, forKey: "subscription")
            next.setValue(sequence, forKey: "sequenceID")
            next.setValue(message.id, forKey: "eventID")
            next.setValue(message.time, forKey: "time")
            next.setValue(message.event, forKey: "event")
            next.setValue((message.time == lastTime ? seen.union([message.id]) : Set([message.id])).sorted().joined(separator: ","), forKey: "seenIDs")
            states[sequence] = next

            if message.isControl {
                if let row {
                    if message.event == "message_clear" { row.read = true }
                    else {
                        deleteAttachmentLocalFile(for: row)
                        context.delete(row)
                    }
                }
                removals.append(SequenceRemoval(baseUrl: subscription.baseUrl ?? "", topic: message.topic,
                                                sequence: sequence, throughTime: message.time))
            } else {
                let notification = row ?? Notification(context: context)
                message.isUpdate = row != nil
                if row == nil { notification.read = false }
                else {
                    deleteAttachmentLocalFile(for: notification)
                    removals.append(SequenceRemoval(baseUrl: subscription.baseUrl ?? "", topic: message.topic,
                                                    sequence: sequence, throughTime: message.time, keepingID: message.id))
                }
                notification.sequenceKey = sequenceKey
                populate(notification, from: item)
                notification.subscription = subscription
                subscription.addToNotifications(notification)
                if row == nil { rows.append(notification) }
                presentations.append(message)
            }
        }
        if !subscription.sequenceReconcile, let last = ingested.last(where: { $0.message.topic == subscription.topic && ($0.message.event == "message" || $0.message.isControl) })?.message {
            var orderedSince = polledSince
            if !isPush, let current = subscription.lastNotificationId,
               let currentPosition = positions[current], let lastPosition = positions[last.id], lastPosition > currentPosition {
                orderedSince = current
            }
            try advanceCursor(of: subscription, to: last, polledSince: orderedSince)
        }
        try context.save()
        removals.forEach(notificationRemover)
        // A single poll can contain create -> update -> clear/delete. Only the final unread version
        // may alert; intermediate versions must never produce a second notification.
        return presentations.filter { message in
            rows.contains { !$0.isDeleted && $0.id == message.id && (!$0.read || message.isUpdate) }
                && states[message.sequence]?.value(forKey: "event") as? String == "message"
        }
    }

    private func populate(_ notification: Notification, from item: IngestedMessage) {
        let message = item.message
        notification.encryption = item.encryption.rawValue
        notification.ciphertext = item.ciphertext
        notification.jweIV = item.iv
        notification.sequenceID = message.sequenceID.flatMap { $0.isEmpty ? nil : $0 }
        notification.id = message.id
        notification.time = message.time
        notification.message = message.message ?? ""
        notification.contentType = message.contentType
        notification.icon = message.icon
        notification.title = message.title ?? ""
        notification.priority = Store.clampPriority(message.priority)
        notification.tags = message.tags?.joined(separator: ",") ?? ""
        notification.actions = Actions.shared.encode(message.actions)
        notification.click = message.click ?? ""
        notification.attachmentName = message.attachment?.name
        notification.attachmentType = message.attachment?.type
        notification.attachmentSize = message.attachment?.size ?? 0
        notification.attachmentExpires = message.attachment?.expires ?? 0
        notification.attachmentUrl = message.attachment?.url
        if
            let attachment = message.attachment,
            let remoteUrl = URL(string: attachment.url),
            let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
                notificationID: message.id,
                remoteUrl: remoteUrl,
                attachment: attachment,
                mimeType: attachment.type
            )
        {
            notification.attachmentLocalPath = localFileUrl.path
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
        } else {
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
        }
    }


    /// Moves the poll cursor (`since=`) to `candidate`, but never backward. Polls and pushes can
    /// land out of order (a slow poll started earlier lands after a push the extension stored), and a
    /// late response ends on an older message; adopting it re-fetches a window the app already has.
    ///
    /// A strictly older candidate is always refused, even from a poll that asked `since=` the
    /// current cursor, because ntfy answers an unknown `since` id with its cached history. Message
    /// times have one-second resolution, so a candidate from the same second can't be ordered by
    /// time: it is refused unless it comes from a poll that asked from the current cursor
    /// (`polledSince`). A cursor that is unset, or whose message is gone (deleted), can always move.
    private func advanceCursor(of subscription: Subscription, to candidate: Message, polledSince: String?) throws {
        if let currentId = subscription.lastNotificationId, currentId != candidate.id {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND subscription == %@", currentId, subscription)
            request.fetchLimit = 1
            if let current = try context.fetch(request).first {
                if candidate.time < current.time { return }
                if candidate.time == current.time, currentId != polledSince { return }
            }
        }
        if candidate.time < subscription.lastEventTime { return }
        if candidate.time == subscription.lastEventTime, let current = subscription.lastNotificationId,
           current != candidate.id, current != polledSince { return }
        subscription.lastNotificationId = candidate.id
        subscription.lastEventTime = candidate.time
    }

    private func deleteAttachmentLocalFile(for notification: Notification) {
        if let localPath = notification.attachmentLocalPath, !localPath.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: localPath))
            notification.attachmentLocalPath = nil
        }
    }
}

extension Store {
    static let sampleMessages = [
        "stats": [
            // TODO: Message with action
            Message(id: "1", time: 1653048956, event: "message", topic: "stats", message: "In the last 24 hours, hyou had 5,000 users across 13 countries visit your website", title: "Record visitor numbers", priority: 4, tags: ["smile", "server123", "de"], actions: nil),
            Message(id: "2", time: 1653058956, event: "message", topic: "stats", message: "201 users/h\n80 IPs", title: "This is a title", priority: 1, tags: [], actions: nil),
            Message(id: "3", time: 1643058956, event: "message", topic: "stats", message: "This message does not have a title, but is instead super long. Like really really long. It can't be any longer I think. I mean, there is s 4,000 byte limit of the message, so I guess I have to make this 4,000 bytes long. Or do I? 😁 I don't know. It's quite tedious to come up with something so long, so I'll stop now. Bye!", title: nil, priority: 5, tags: ["facepalm"], actions: nil)
        ],
        "backups": [],
        "announcements": [],
        "alerts": [],
        "playground": []
    ]
    
    static var preview: Store = {
        let store = Store(inMemory: true)
        store.context.perform {
            // Subscriptions and notifications
            sampleMessages.forEach { topic, messages in
                store.makeSubscription(store.context, topic, messages)
            }
            
            // Users
            store.saveUser(baseUrl: "https://ntfy.sh", username: "testuser", password: "testuser")
            store.saveUser(baseUrl: "https://ntfy.example.com", username: "phil", password: "phil12")
        }
        return store
    }()
    
    static var previewEmpty: Store = {
        return Store(inMemory: true)
    }()
    
    @discardableResult
    func makeSubscription(_ context: NSManagedObjectContext, _ topic: String, _ messages: [Message]) -> Subscription {
        let notifications = messages.map { message in
            let notification = Notification(context: context)
            notification.id = message.id
            notification.time = message.time
            notification.message = message.message
            notification.contentType = message.contentType
            notification.icon = message.icon
            notification.title = message.title
            notification.priority = message.priority ?? 3
            notification.tags = message.tags?.joined(separator: ",") ?? ""
            notification.attachmentName = message.attachment?.name
            notification.attachmentType = message.attachment?.type
            notification.attachmentSize = message.attachment?.size ?? 0
            notification.attachmentExpires = message.attachment?.expires ?? 0
            notification.attachmentUrl = message.attachment?.url
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
            return notification
        }
        let subscription = Subscription(context: context)
        subscription.baseUrl = Config.appBaseUrl
        subscription.topic = topic
        subscription.notifications = NSSet(array: notifications)
        return subscription
    }
}

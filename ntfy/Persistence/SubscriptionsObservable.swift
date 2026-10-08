import CoreData
import SwiftUI

class SubscriptionsObservable: NSObject, ObservableObject {
    private let tag = "SubscriptionsObservable"
    
    private var remoteChangeObserver: NSObjectProtocol?
    private var sortOrderObserver: NSObjectProtocol?

    override init() {
        super.init()

        // This will force the initialization of notificationsFetchedResultsController
        _ = self.notificationsFetchedResultsController

        // A push written by the notification service extension's process never reaches these
        // fetched-results controllers on its own — controller membership changes only when the
        // context it observes processes a save, and a cross-process commit never produces one. So
        // a message arriving while the topic list was on screen left the row's unread badge and
        // notification count stale until the user navigated away and back.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: Store.didChangeRemotely, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refetch()
        }

        // A sort-order change moves no rows in the database, so it gets its own signal rather than
        // borrowing the cross-process one: that would make every open topic's NotificationsObservable
        // re-run its fetch to change nothing but presentation order.
        sortOrderObserver = NotificationCenter.default.addObserver(
            forName: Store.topicSortOrderDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.invalidateOrder()
            self.objectWillChange.send()
        }
    }

    deinit {
        if let remoteChangeObserver = remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
        }
        if let sortOrderObserver = sortOrderObserver {
            NotificationCenter.default.removeObserver(sortOrderObserver)
        }
    }

    /// Re-runs both fetches against the store and tells SwiftUI to re-render. Internal rather than
    /// private so a test can drive it directly; production only reaches it through the
    /// remote-change broadcast.
    func refetch() {
        // Drop the cached order first. Re-fetching without this returns fresh rows to a stale
        // array — a push arriving while the app is open would update nothing on screen, which is
        // exactly the ntfy#337 bug whose test caught this.
        invalidateOrder()
        // Each controller gets its own catch: sharing one meant a throw from the first silently
        // skipped the second, and the view was then told to re-render off entirely stale state.
        var refreshed = false
        do {
            try fetchedResultsController.performFetch()
            refreshed = true
        } catch {
            Log.w(tag, "Failed to re-fetch subscriptions after a remote change: \(error)", error)
        }
        do {
            try notificationsFetchedResultsController.performFetch()
            refreshed = true
        } catch {
            Log.w(tag, "Failed to re-fetch notifications after a remote change: \(error)", error)
        }
        guard refreshed else { return } // nothing moved; don't churn a render for stale state
        objectWillChange.send()
    }
    
    private lazy var fetchedResultsController: NSFetchedResultsController<Subscription> = {
        let fetchRequest: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "topic", ascending: true)]
        
        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self
        
        do {
            Log.d(tag, "Fetching subscriptions")
            try controller.performFetch()
        } catch {
            Log.w(tag, "Failed to fetch subscriptions: \(error)", error)
        }
        
        return controller
    }()
    
    private lazy var notificationsFetchedResultsController: NSFetchedResultsController<Notification> = {
        let fetchRequest: NSFetchRequest<Notification> = Notification.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)]
        // This controller exists only to notice that *some* notification changed, so the rows can
        // re-render their counts and unread badges — nothing reads its results. It has no predicate,
        // so on an install with a long history it would otherwise fault in every notification the
        // user has ever received on each re-fetch.
        fetchRequest.fetchBatchSize = 50
        
        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self
        
        do {
            Log.d(tag, "Fetching notifications")
            try controller.performFetch()
        } catch {
            Log.w(tag, "Failed to fetch notifications: \(error)", error)
        }
        
        return controller
    }()
    
    /// The ordered list, computed once and reused until something actually changes it.
    ///
    /// `subscriptions` is read several times per render path — `ForEach`, the empty-state check,
    /// and the poll-on-appear — and in recent-activity mode each read would otherwise re-run the
    /// `max(time)` aggregate against the main-queue context. Not once per row (ForEach gets one
    /// materialized array), but several times per render for data that has not moved.
    private var cachedOrder: [Subscription]?
    private var cachedSummaries: [NSManagedObjectID: Store.SubscriptionSummary]?

    /// Row data for the whole list, resolved by aggregate query rather than by each row faulting
    /// its topic's entire history. Cached with the order because they invalidate together.
    var summaries: [NSManagedObjectID: Store.SubscriptionSummary] {
        if let cachedSummaries = cachedSummaries { return cachedSummaries }
        guard var computed = Store.shared.subscriptionSummaries() else {
            // The aggregate failed. Return nothing rather than zeros: a zero summary would show
            // every topic as empty, badges and all. An empty map sends each row down the
            // per-object fallback — slower, but right.
            //
            // Cache the failure too. Without this, every row's lookup retries both grouped fetches,
            // so one broken query becomes 2N failing fetches and 2N log lines per render before the
            // fallback even runs. invalidateOrder() clears it, so the next FRC change, re-fetch or
            // preference change retries properly.
            cachedSummaries = [:]
            return [:]
        }
        // A topic with no messages has no group in the aggregate, so it would arrive here as nil
        // and send the row down the per-object fallback — which faults its (empty) relationship,
        // once per such row after a relaunch. Fill in an explicit zero instead: the row then never
        // touches the relationship, and "no activity" is still distinguishable from a time of zero
        // because lastTime stays nil.
        for subscription in fetchedResultsController.fetchedObjects ?? []
        where computed[subscription.objectID] == nil {
            computed[subscription.objectID] = Store.SubscriptionSummary(total: 0, unread: 0, lastTime: nil)
        }
        cachedSummaries = computed
        return computed
    }

    var subscriptions: [Subscription] {
        if let cachedOrder = cachedOrder { return cachedOrder }
        let ordered = computeOrder()
        cachedOrder = ordered
        return ordered
    }

    /// Drop the cache. Called when the fetched results change, when a re-fetch runs, and when the
    /// sort preference changes — the only three things that can alter the order.
    private func invalidateOrder() {
        cachedOrder = nil
        cachedSummaries = nil
    }

    /// Pinned topics first, then everything else; the user's chosen sort order applies within each
    /// group, so pinning never scrambles the order they picked — it only lifts a topic above it.
    private func computeOrder() -> [Subscription] {
        let sorted = sortedBySortOrder(fetchedResultsController.fetchedObjects ?? [])
        return sorted.filter { $0.pinned } + sorted.filter { !$0.pinned }
    }

    private func sortedBySortOrder(_ fetched: [Subscription]) -> [Subscription] {
        switch Store.shared.getTopicSortOrder() {
        case .name:
            // Sorted here rather than by the fetch request, which orders on the raw `topic`. After
            // a rename that bears no relation to the label the row actually shows, so the list
            // looked arbitrarily ordered to anyone who had renamed a topic.
            return fetched.sorted { byDisplayName($0, $1) }
        case .recentActivity:
            // Reuses the summaries computed for the rows — see Store.subscriptionSummaries. A topic
            // with no messages yet has no entry and sorts last, but keeps a stable alphabetical
            // order among its peers rather than jittering on every re-render.
            let times = summaries.mapValues { $0.lastTime }
            return fetched.sorted { lhs, rhs in
                let lhsTime = times[lhs.objectID] ?? nil
                let rhsTime = times[rhs.objectID] ?? nil
                if let lhsTime = lhsTime, let rhsTime = rhsTime, lhsTime != rhsTime {
                    return lhsTime > rhsTime
                }
                if (lhsTime == nil) != (rhsTime == nil) {
                    return lhsTime != nil
                }
                return byDisplayName(lhs, rhs)
            }
        }
    }

    /// Alphabetical by visible name, with the object ID as a final tie-breaker.
    ///
    /// Swift's sort is not guaranteed stable, so two topics sharing a display name — easy to do,
    /// since custom names are free text — would otherwise have no defined order and could swap
    /// between renders. The URI is arbitrary but permanent, which is all this needs.
    private func byDisplayName(_ lhs: Subscription, _ rhs: Subscription) -> Bool {
        switch lhs.shortDisplayName().localizedCaseInsensitiveCompare(rhs.shortDisplayName()) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            return lhs.objectID.uriRepresentation().absoluteString
                < rhs.objectID.uriRepresentation().absoluteString
        }
    }

}

extension SubscriptionsObservable: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        invalidateOrder()
        Log.d(tag, "Fetching notifications")
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}

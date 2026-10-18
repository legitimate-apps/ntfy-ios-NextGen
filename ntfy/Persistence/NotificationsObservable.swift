import CoreData
import SwiftUI
import Combine

/// A bounded window, updated from context change IDs (including merged NSE history).
/// Older pages use (time, id), so a new push never shifts a fetch offset or skips a row.
class NotificationsObservable: NSObject, ObservableObject {
    static let pageSize = 50
    private let subscriptionID: NSManagedObjectID
    private let context: NSManagedObjectContext
    private var observers: [NSObjectProtocol] = []
    private var searchSubscription: AnyCancellable?
    private let searchInput = PassthroughSubject<String, Never>()
    private var query = ""
    private var capacity = pageSize
    @Published private(set) var notifications: [Notification] = []
    @Published private(set) var hasOlder = false
    private(set) var fetchCount = 0

    init(subscriptionID: NSManagedObjectID, context: NSManagedObjectContext = Store.shared.context) {
        self.subscriptionID = subscriptionID
        self.context = context
        super.init()
        refetch()
        searchSubscription = searchInput.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.search($0) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: nil
        ) { [weak self] in self?.apply($0) })
        observers.append(NotificationCenter.default.addObserver(
            forName: Store.didResetHistory, object: nil, queue: .main
        ) { [weak self] _ in self?.refetch() })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func predicate() -> NSPredicate {
        let topic = NSPredicate(format: "subscription == %@", subscriptionID)
        guard !query.isEmpty else { return topic }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [topic,
            NSPredicate(format: "message CONTAINS[cd] %@ OR title CONTAINS[cd] %@", query, query)])
    }

    private func fetch(limit: Int, before row: Notification? = nil) throws -> [Notification] {
        let request = Notification.fetchRequest()
        var filters = [predicate()]
        if let row, let id = row.id {
            filters.append(NSPredicate(format: "time < %lld OR (time == %lld AND id < %@)", row.time, row.time, id))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: filters)
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false), NSSortDescriptor(key: "id", ascending: false)]
        request.fetchBatchSize = Self.pageSize
        request.fetchLimit = limit
        fetchCount += 1
        return try context.fetch(request)
    }

    /// Explicit refresh resets the window. Pushes use `apply`, without fetching the window again.
    func refetch() {
        do {
            let page = try fetch(limit: Self.pageSize + 1)
            capacity = Self.pageSize
            hasOlder = page.count > Self.pageSize
            notifications = Array(page.prefix(Self.pageSize))
        } catch { Log.w("NotificationsObservable", "Cannot load notifications", error) }
    }

    func scheduleSearch(_ text: String) { searchInput.send(text) }

    func search(_ text: String) {
        guard query != text else { return }
        query = text
        refetch()
    }

    func loadOlder() {
        guard hasOlder, let last = notifications.last else { return }
        do {
            let page = try fetch(limit: Self.pageSize + 1, before: last)
            capacity += Self.pageSize
            hasOlder = page.count > Self.pageSize
            notifications += page.prefix(Self.pageSize)
        } catch { Log.w("NotificationsObservable", "Cannot load older notifications", error) }
    }

    private func apply(_ change: Foundation.Notification) {
        guard let info = change.userInfo else { return }
        if info[NSInvalidatedAllObjectsKey] != nil { refetch(); return }
        let removed = (info[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? [])
            .union(info[NSInvalidatedObjectsKey] as? Set<NSManagedObject> ?? [])
        let changed = (info[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? [])
            .union(info[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? [])
            .union(info[NSRefreshedObjectsKey] as? Set<NSManagedObject> ?? [])
        let removedIDs = Set(removed.map(\.objectID))
        let loadedIDs = Set(notifications.map(\.objectID))
        let rows = changed.compactMap { $0 as? Notification }.filter {
            loadedIDs.contains($0.objectID) || (!$0.isDeleted && $0.subscription?.objectID == subscriptionID)
        }
        guard !removedIDs.isDisjoint(with: loadedIDs) || !rows.isEmpty else { return }
        let changedIDs = Set(rows.map(\.objectID))
        var result = notifications.filter { !removedIDs.contains($0.objectID) && !changedIDs.contains($0.objectID) }
        let boundary = notifications.last { !removedIDs.contains($0.objectID) && !$0.isDeleted }
        for row in rows where !row.isDeleted && row.managedObjectContext != nil && matches(row) {
            // Keep a contiguous window. A changed row beyond its bottom belongs to a later page.
            if !hasOlder || boundary.map({ precedes(row, $0) || row.objectID == $0.objectID }) != false {
                result.append(row)
            }
        }
        result.sort(by: precedes)
        if result.count > capacity { hasOlder = true; result = Array(result.prefix(capacity)) }
        notifications = result // synchronous: deleted objects must leave before SwiftUI renders
        // Fill holes with a bounded keyset fetch; never re-materialize the existing window.
        if hasOlder, result.count < capacity {
            do {
                let missing = capacity - result.count
                let page = try fetch(limit: missing + 1, before: result.last)
                hasOlder = page.count > missing
                notifications += page.prefix(missing)
            } catch { Log.w("NotificationsObservable", "Cannot fill notification page", error) }
        }
    }

    private func matches(_ row: Notification) -> Bool {
        guard row.subscription?.objectID == subscriptionID else { return false }
        return query.isEmpty || NSPredicate(format: "message CONTAINS[cd] %@ OR title CONTAINS[cd] %@", query, query).evaluate(with: row)
    }

    private func precedes(_ lhs: Notification, _ rhs: Notification) -> Bool {
        lhs.time != rhs.time ? lhs.time > rhs.time : (lhs.id ?? "") > (rhs.id ?? "")
    }
}

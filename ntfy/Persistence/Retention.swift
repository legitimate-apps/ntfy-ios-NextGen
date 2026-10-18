import CoreData
import Foundation
import UserNotifications
import Combine

/// Values match ntfy Android's global auto-delete options. Expiry uses message time.
enum NotificationRetention: Int64, CaseIterable {
    case forever = 0, day = 1, threeDays = 3, week = 7, month = 30, threeMonths = 90
    var seconds: Int64 { rawValue * 86_400 }
    var label: String {
        switch self {
        case .forever: return "Forever"
        case .day: return "1 day"
        case .threeDays: return "3 days"
        case .week: return "1 week"
        case .month: return "1 month (30 days)"
        case .threeMonths: return "3 months (90 days)"
        }
    }
}

enum NotificationHistoryStrings {
    static let title = "Keep notifications"
    static let section = "Notification history"
    static let explanation = "Notifications older than this are permanently deleted from this device, read or unread, with downloaded attachments and matching banners in Notification Center. Age counts from the message date. Deletion runs while the app is open. Messages that just arrived and recently downloaded files are kept for an hour. Other devices are not affected."
    static let loadOlder = "Load older notifications"
    static let noMatches = "No notifications match your search."
    static let search = "Search all notifications"
    static func confirmation(_ count: Int, _ policy: NotificationRetention) -> String {
        "Delete \(count) notifications older than \(policy.label)?"
    }
    static let confirmExplanation = "This permanently deletes eligible notifications and their downloaded attachments from this device, including unread notifications. Messages in the one-hour grace period are kept until they expire."
    static let delete = "Delete notifications"
    static let cancel = "Cancel"
    static let saveError = "Could not save the setting"
    static let saveErrorExplanation = "Your previous retention setting is still in use. Try again."
}

extension Store {
    static let retentionPreferenceKey = "notificationRetentionDays"

    /// Adopt prior use without silently deleting history on upgrade. A fresh store uses Android's
    /// 30-day default. Persist the decision, so clearing a topic never changes the chosen policy.
    func notificationRetention() -> NotificationRetention {
        var result = NotificationRetention.forever
        retentionReadContext.performAndWait {
            retentionReadContext.reset()
            do { result = try resolveRetention(in: retentionReadContext) }
            catch { Log.w(Store.tag, "Cannot read notification retention", error) }
        }
        return result
    }

    @discardableResult
    func saveNotificationRetention(_ policy: NotificationRetention) -> Bool {
        var saved = false
        context.performAndWait {
            retentionPolicyLock.lock()
            defer { retentionPolicyLock.unlock() }
            do {
                let request = Preference.fetchRequest()
                request.predicate = NSPredicate(format: "key == %@", Self.retentionPreferenceKey)
                let pref = try context.fetch(request).first ?? Preference(context: context)
                pref.key = Self.retentionPreferenceKey
                pref.value = String(policy.rawValue)
                try context.save()
                retentionPolicyGeneration &+= 1
                saved = true
            } catch { Log.w(Store.tag, "Cannot save notification retention", error); context.rollback() }
        }
        if saved { pruneNotifications() }
        return saved
    }

    func resolveRetention(in context: NSManagedObjectContext) throws -> NotificationRetention {
        let request = Preference.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", Self.retentionPreferenceKey)
        if let pref = try context.fetch(request).first {
            // Unknown future values fail safe instead of deleting someone's history.
            return Int64(pref.value ?? "").flatMap(NotificationRetention.init(rawValue:)) ?? .forever
        }
        var existing = hadPersistentStore
        for entity in ["Subscription", "Notification", "User", "Preference", "SequenceState"] where !existing {
            let rows = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            rows.fetchLimit = 1
            existing = try context.count(for: rows) > 0
        }
        let policy: NotificationRetention = existing ? .forever : .month
        let pref = Preference(context: context)
        pref.key = Self.retentionPreferenceKey
        pref.value = String(policy.rawValue)
        try context.save()
        return policy
    }

    private func retentionGeneration() -> UInt64 {
        retentionPolicyLock.lock()
        defer { retentionPolicyLock.unlock() }
        return retentionPolicyGeneration
    }

    /// Linearize a local setting write against the actual deletion commit, not just its fetch.
    /// A changed policy discards the entire pending transaction, including attachment/evidence work.
    private func saveRetentionBatch(ifGeneration generation: UInt64) throws -> Bool {
        retentionPolicyLock.lock()
        defer { retentionPolicyLock.unlock() }
        guard retentionPolicyGeneration == generation else {
            retentionContext.reset()
            return false
        }
        try retentionContext.save()
        return true
    }

    /// All fetch/delete/unlink work runs on a private queue. Each save is at most 200 rows.
    /// Default error merge policy is intentional: an NSE update after the fetch must abort that
    /// chunk, not let a store-trump merge silently delete the newly updated row. Files go only
    /// after a successful commit. No directory sweep can unlink an attachment still being written.
    func pruneNotifications(now: Date = Date(), completion: ((Result<Int, Error>) -> Void)? = nil) {
        retentionContext.perform {
            self.retentionContext.reset()
            do {
                let request = Notification.fetchRequest()
                request.fetchLimit = 200
                request.fetchBatchSize = 200
                var count = 0
                while true {
                    let generation = self.retentionGeneration()
                    let policy = try self.resolveRetention(in: self.retentionContext)
                    guard policy != .forever else { break }
                    request.predicate = NSPredicate(format: "time < %lld AND (storedAt == nil OR storedAt < %@)",
                        Int64(now.timeIntervalSince1970) - policy.seconds, now.addingTimeInterval(-3600) as NSDate)
                    let rows = try self.retentionContext.fetch(request)
                    guard !rows.isEmpty else { break }
                    self.retentionCandidatesFetched?()
                    let paths = Set(rows.compactMap(\.attachmentLocalPath).filter { !$0.isEmpty })
                    let pending = NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")
                    pending.predicate = NSPredicate(format: "path IN %@", Array(paths))
                    let queued = Set(try self.retentionContext.fetch(pending).compactMap { $0.value(forKey: "path") as? String })
                    for path in paths.subtracting(queued) {
                        let entry = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: self.retentionContext)
                        entry.setValue(path, forKey: "path")
                    }
                    let banners = rows.compactMap { row -> SequenceRemoval? in
                        guard let sub = row.subscription, let baseUrl = sub.baseUrl,
                              let topic = sub.topic, let id = row.id else { return nil }
                        return SequenceRemoval(baseUrl: baseUrl, topic: topic, sequence: row.sequenceID ?? id, throughTime: row.time)
                    }
                    try self.archivePresentedDeliveries(rows, in: self.retentionContext)
                    rows.forEach(self.retentionContext.delete)
                    guard try self.saveRetentionBatch(ifGeneration: generation) else { continue }
                    // One system query per chunk, rather than one per expired message.
                    if !banners.isEmpty {
                        let center = UNUserNotificationCenter.current()
                        center.getDeliveredNotifications { delivered in
                            let ids = delivered.filter { banner in
                                banners.contains { $0.matches(userInfo: banner.request.content.userInfo) }
                            }.map { $0.request.identifier }
                            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
                        }
                    }
                    count += rows.count
                    self.retentionContext.reset()
                }
                // Sequence deduplication tombstones also need a bound. Keep at least 120 days,
                // matching Android's hard-delete window, so delayed controls cannot revive history.
                let states = NSFetchRequest<NSManagedObject>(entityName: "SequenceState")
                states.fetchLimit = 200
                while true {
                    let generation = self.retentionGeneration()
                    let policy = try self.resolveRetention(in: self.retentionContext)
                    guard policy != .forever else { break }
                    states.predicate = NSPredicate(format: "time < %lld AND (storedAt == nil OR storedAt < %@)",
                        Int64(now.timeIntervalSince1970) - max(policy.seconds, 120 * 86_400), now.addingTimeInterval(-3600) as NSDate)
                    let rows = try self.retentionContext.fetch(states)
                    guard !rows.isEmpty else { break }
                    rows.forEach(self.retentionContext.delete)
                    guard try self.saveRetentionBatch(ifGeneration: generation) else { continue }
                    self.retentionContext.reset()
                }
                try self.removeExpiredAttachmentFiles(now: now)
                // History is only used by live processes; new processes start at the current token.
                _ = try self.retentionContext.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: now.addingTimeInterval(-7 * 86_400)))
                completion?(.success(count))
            } catch {
                self.retentionContext.rollback()
                self.retentionContext.reset()
                Log.w(Store.tag, "Cannot prune notification history; will retry on next maintenance", error)
                completion?(.failure(error))
            }
        }
    }

    /// Queue entries commit atomically with row deletion. A crash or failed unlink can therefore
    /// retry next time. Only exact retired paths are considered; never sweep the shared directory.
    private func removeExpiredAttachmentFiles(now: Date) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")
        request.fetchLimit = 200
        request.sortDescriptors = [NSSortDescriptor(key: "path", ascending: true)]
        var after = ""
        while true {
            request.predicate = NSPredicate(format: "path > %@", after)
            let entries = try retentionContext.fetch(request)
            guard !entries.isEmpty else { break }
            for entry in entries {
                guard let path = entry.value(forKey: "path") as? String else { continue }
                after = path
                do {
                    let removed = try AttachmentFileStore.withFileAccess(at: URL(fileURLWithPath: path)) {
                        let live = Notification.fetchRequest()
                        live.predicate = NSPredicate(format: "attachmentLocalPath == %@", path)
                        if try retentionContext.count(for: live) > 0 { return true } // path is owned again
                        let attributes = try FileManager.default.attributesOfItem(atPath: path)
                        // A download may finish before its row is saved. The shared file lock
                        // makes this check atomic with replacement by the app or NSE downloader.
                        if let modified = attributes[.modificationDate] as? Date,
                           modified > now.addingTimeInterval(-3600) { return false }
                        try FileManager.default.removeItem(atPath: path)
                        return true
                    }
                    if removed { retentionContext.delete(entry) }
                } catch let error as NSError {
                    if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
                        || (error.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(error.code)) {
                        retentionContext.delete(entry)
                    } else { Log.w(Store.tag, "Cannot remove expired attachment; queued for retry", error) }
                }
            }
            try retentionContext.save()
            retentionContext.reset()
        }
    }

    /// Count the same candidates as pruning, without materializing rows on the UI queue.
    func countExpiringNotifications(under policy: NotificationRetention, now: Date = Date(), completion: @escaping (Result<Int, Error>) -> Void) {
        retentionContext.perform {
            do {
                let request = Notification.fetchRequest()
                request.predicate = NSPredicate(format: "time < %lld AND (storedAt == nil OR storedAt < %@)",
                    Int64(now.timeIntervalSince1970) - policy.seconds, now.addingTimeInterval(-3600) as NSDate)
                let count = policy == .forever ? 0 : try self.retentionContext.count(for: request)
                DispatchQueue.main.async { completion(.success(count)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    /// Archive only deleted delivery evidence, atomically with its row deletion. No independent
    /// defaults read-modify-write can lose an NSE's concurrent delivery. The eligibility policy
    /// needs two distinct days; keep the earliest/latest evidence plus the exact lifetime count.
    struct ArchivedDeliveries: Codable {
        var count = 0
        var first: Int64?
        var last: Int64?
        var times: [Int64] { [first, last].compactMap { $0 } }
    }
    static let archivedDeliveriesKey = "retentionPresentedDeliveries"

    func archivedDeliveries(in context: NSManagedObjectContext) throws -> (Preference?, ArchivedDeliveries) {
        let request = Preference.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", Self.archivedDeliveriesKey)
        let pref = try context.fetch(request).first
        let evidence = try pref?.value.map { try JSONDecoder().decode(ArchivedDeliveries.self, from: Data($0.utf8)) }
        return (pref, evidence ?? ArchivedDeliveries())
    }

    func archivePresentedDeliveries(_ rows: [Notification], in context: NSManagedObjectContext) throws {
        let times = rows.filter { $0.presented && !($0.message ?? "").hasPrefix(Self.testMessagePrefix) }.map(\.time)
        guard !times.isEmpty else { return }
        var (pref, evidence) = try archivedDeliveries(in: context)
        evidence.count += times.count
        let all = evidence.times + times
        evidence.first = all.min(); evidence.last = all.max()
        if pref == nil { pref = Preference(context: context); pref?.key = Self.archivedDeliveriesKey }
        pref?.value = String(data: try JSONEncoder().encode(evidence), encoding: .utf8)
    }

    /// The NSE also writes history while the app is closed. A bounded timestamp trim needs no
    /// message fetch or migration of the view context; stale app tokens take the recovery path.
    func trimPersistentHistory(now: Date = Date(), completion: (() -> Void)? = nil) {
        retentionContext.perform {
            do { _ = try self.retentionContext.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: now.addingTimeInterval(-7 * 86_400))) }
            catch { Log.w(Self.tag, "Cannot trim persistent history", error) }
            completion?()
        }
    }

}

/// The picker reads its stored value at construction and never commits a shorter limit before
/// explicit confirmation. Keeping this state machine out of the view makes Cancel testable.
final class RetentionSelection: ObservableObject {
    struct Prompt: Identifiable {
        let id = UUID()
        let policy: NotificationRetention?
        let count: Int
    }
    @Published private(set) var policy: NotificationRetention
    @Published var prompt: Prompt?
    private let store: Store
    private var generation = 0

    init(store: Store) { self.store = store; policy = store.notificationRetention() }

    func select(_ value: NotificationRetention) {
        generation += 1
        let currentGeneration = generation
        let previous = store.notificationRetention()
        policy = value
        guard value != previous else { return }
        let shorter = value != .forever && (previous == .forever || value.seconds < previous.seconds)
        if !shorter { save(value); return }
        store.countExpiringNotifications(under: value) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            switch result {
            case .success(let count): self.prompt = Prompt(policy: value, count: count)
            case .failure: self.policy = previous; self.prompt = Prompt(policy: nil, count: 0)
            }
        }
    }

    func cancel() { generation += 1; policy = store.notificationRetention(); prompt = nil }
    func confirm(_ value: NotificationRetention) { prompt = nil; save(value) }
    private func save(_ value: NotificationRetention) {
        if !store.saveNotificationRetention(value) {
            policy = store.notificationRetention(); prompt = Prompt(policy: nil, count: 0)
        }
    }
}

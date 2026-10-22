import XCTest
import CoreData
import Combine
import UserNotifications
@testable import ntfy

final class RetentionTests: XCTestCase {
    private var store: Store { Store.shared }
    private var subscriptions: [ntfy.Subscription] = []

    override func setUp() {
        super.setUp()
        store.clearPublisher = { _, done in done(.sent) }
        installClearPacer()
        if store.notificationRetention() != .forever { store.saveNotificationRetention(.forever) }
        store.notificationRemover = { _ in }
        store.notificationBatchRemover = { _ in }
        store.topicNotificationRemover = { _, _, _, _ in }
        store.wakePublisher = { _, done in done() }
    }

    private func installClearPacer() {
        let pacer = ClearPacer()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        pacer.now = { clock }
        pacer.schedule = { delay, work in clock += delay; work() }
        store.clearPacer = pacer
    }

    override func tearDown() {
        store.context.performAndWait {
            subscriptions.forEach { store.context.delete($0) }
            try? store.context.save()
        }
        subscriptions = []
        super.tearDown()
    }

    private func closeDiskStores(_ stores: [Store]) {
        for store in stores {
            store.retentionContext.performAndWait { store.retentionContext.reset() }
            store.context.performAndWait {
                store.context.automaticallyMergesChangesFromParent = false
                store.context.reset()
            }
            let coordinator = store.container.persistentStoreCoordinator
            for disk in coordinator.persistentStores { try? coordinator.remove(disk) }
        }
    }

    private func fixture(_ count: Int) throws -> ntfy.Subscription {
        let subscription = store.saveSubscription(baseUrl: "https://retention.example", topic: "scale-\(UUID().uuidString)")
        subscriptions.append(subscription)
        for i in 0..<count {
            let row = ntfy.Notification(context: store.context)
            row.id = "fixture-\(subscription.topic!)-\(i)"
            row.time = Int64(1_790_000_000 + i)
            row.message = "Monitoring sample \(i): backup completed"
            row.title = "Backup \(i)"
            row.priority = 3
            row.read = true
            row.subscription = subscription
        }
        try store.context.save()
        store.hardRefresh()
        return subscription
    }

    func testRetentionRemovesExpiredRowsAndFilesButKeepsBoundaryAndFreshWrites() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.month)
        isolated.retentionContext.performAndWait {} // the save starts a prune; finish it before inserting rows
        let context = isolated.context
        let subscription = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "expiry")
        let now = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rows: [String: ntfy.Notification] = [:]
        for (id, age, fresh) in [("old", 31, false), ("boundary", 30, false), ("new", 2, false), ("incoming", 60, true)] {
            let row = ntfy.Notification(context: context)
            row.id = "retention-" + id
            row.message = id
            row.time = Int64(now.timeIntervalSince1970) - Int64(age * 86_400)
            row.subscription = subscription
            row.storedAt = fresh ? now : nil // nil models rows migrated from Model 6
            let file = dir.appendingPathComponent(id)
            try Data(id.utf8).write(to: file)
            if !fresh { try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path) }
            row.attachmentLocalPath = file.path
            rows[id] = row
        }
        try context.save()
        let done = expectation(description: "background expiry committed")
        isolated.pruneNotifications(now: now) { result in
            XCTAssertFalse(Thread.isMainThread, "expiry and file cleanup run off main")
            XCTAssertEqual(try? result.get(), 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        context.performAndWait {
            let remaining = try? context.fetch(ntfy.Notification.fetchRequest())
            XCTAssertEqual(Set(remaining?.compactMap(\.id) ?? []), ["retention-boundary", "retention-new", "retention-incoming"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old").path))
        for id in ["new", "boundary", "incoming"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(id).path))
        }
    }

    func testForeverKeepsAllHistoryAndAttachments() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "forever")
        let row = ntfy.Notification(context: isolated.context)
        row.id = "forever-old"
        row.message = "keep"
        row.time = 1
        row.subscription = sub
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        row.attachmentLocalPath = path.path
        try isolated.context.save()
        let done = expectation(description: "forever finishes")
        isolated.pruneNotifications { result in
            XCTAssertEqual(try? result.get(), 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testSubscriptionOnlyUpgradeAdoptsAndPersistsForever() throws {
        let isolated = Store(inMemory: true)
        _ = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "cleared-before-upgrade")
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        XCTAssertEqual(try isolated.context.count(for: Preference.fetchRequest()), 0)
        XCTAssertEqual(isolated.notificationRetention(), .forever)
        isolated.retentionContext.performAndWait { isolated.retentionContext.reset() }
        isolated.context.reset()
        let request = Preference.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", Store.retentionPreferenceKey)
        XCTAssertEqual(try isolated.context.fetch(request).first?.value, "0", "the upgrade choice must persist even with no history")
    }

    func testEmptyModel6UpgradeAdoptsForeverAndPersistsAcrossReopening() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stores: [Store] = []
        defer { closeDiskStores(stores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty-model6.sqlite")
        try autoreleasepool {
            let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
                .appendingPathComponent("Model 6.mom")
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            try coordinator.remove(disk)
        }
        let migrated = Store(inMemory: true, storeURL: url)
        stores.append(migrated)
        XCTAssertEqual(migrated.notificationRetention(), .forever, "an empty legacy database is still an upgrade")
        let reopened = Store(inMemory: true, storeURL: url)
        stores.append(reopened)
        XCTAssertEqual(reopened.notificationRetention(), .forever)
        let request = Preference.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", Store.retentionPreferenceKey)
        XCTAssertEqual(try reopened.context.fetch(request).first?.value, "0")
    }

    func testForeverSavedBetweenCandidateFetchAndCommitCancelsThatBatch() throws {
        let isolated = Store(inMemory: true)
        XCTAssertTrue(isolated.saveNotificationRetention(.day))
        isolated.retentionContext.performAndWait {} // finish the empty automatic prune
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "change-policy")
        let row = ntfy.Notification(context: isolated.context)
        row.id = "keep-after-forever"; row.message = "history"; row.time = 1; row.subscription = sub
        row.presented = true
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("attachment".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }
        row.attachmentLocalPath = path.path
        try isolated.context.save()
        let switched = expectation(description: "Forever saved after candidates fetched")
        isolated.retentionCandidatesFetched = {
            isolated.retentionCandidatesFetched = nil
            DispatchQueue.main.sync {
                XCTAssertTrue(isolated.saveNotificationRetention(.forever))
                switched.fulfill()
            }
        }
        let done = expectation(description: "stale deletion batch rejected")
        isolated.pruneNotifications { result in
            XCTAssertEqual(try? result.get(), 0)
            done.fulfill()
        }
        wait(for: [switched, done], timeout: 5)
        XCTAssertEqual(isolated.notificationRetention(), .forever)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 0)
        XCTAssertEqual(isolated.presentedDeliveries().count, 1)
    }

    func testPollIngestionDoesNotWaitForThePruneQueue() throws {
        let isolated = Store(inMemory: true)
        XCTAssertTrue(isolated.saveNotificationRetention(.month))
        isolated.retentionContext.performAndWait {}
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "busy-prune")
        let request = try XCTUnwrap(isolated.pollRequest(for: sub))
        let held = expectation(description: "prune queue occupied")
        let release = DispatchSemaphore(value: 0)
        let ingested = DispatchSemaphore(value: 0)
        isolated.retentionContext.perform {
            held.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        wait(for: [held], timeout: 2)
        // A blocked old getter is released after one second so the red cannot hang the runner.
        DispatchQueue.global().async {
            _ = ingested.wait(timeout: .now() + 1)
            release.signal()
        }
        let message = Message(id: "while-pruning", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "busy-prune", message: "fresh")
        let start = CFAbsoluteTimeGetCurrent()
        let saved = isolated.save(notificationsFromMessages: [message], polledWith: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        ingested.signal()
        XCTAssertEqual(saved?.map(\.id), [message.id])
        XCTAssertLessThan(elapsed, 0.5, "ingestion must finish while the retention queue is still held")
        isolated.retentionContext.performAndWait {}
    }

    func testGlobalPruneIndexesStartWithTime() throws {
        for (entity, name) in [("Notification", "notificationRetention"), ("SequenceState", "sequenceRetention")] {
            let description = try XCTUnwrap(store.container.managedObjectModel.entitiesByName[entity])
            let index = try XCTUnwrap(description.indexes.first { $0.name == name })
            XCTAssertEqual(index.elements.map { $0.property?.name }, ["time", "storedAt"])
            XCTAssertTrue(index.elements.allSatisfy { $0.isAscending })
        }
    }

    func testRetentionAdoptionPreservesExistingUsersAndUsesAndroidDefaultForFreshStore() throws {
        let fresh = Store(inMemory: true)
        XCTAssertEqual(fresh.notificationRetention(), .month)
        let existing = Store(inMemory: true)
        let sub = existing.saveSubscription(baseUrl: "https://retention.example", topic: "existing")
        let row = ntfy.Notification(context: existing.context)
        row.id = "before-upgrade"
        row.message = "old history"
        row.time = 1
        row.subscription = sub
        try existing.context.save()
        XCTAssertEqual(existing.notificationRetention(), .forever)
        existing.context.delete(row)
        try existing.context.save()
        XCTAssertEqual(existing.notificationRetention(), .forever, "emptying history must not switch the adopted policy")
    }

    func testLoadOlderAndPushAreIncrementalAndSearchReachesUnloadedHistory() throws {
        let sub = try fixture(151)
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        XCTAssertEqual(model.notifications.count, 50)
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 100)
        XCTAssertEqual(Set(model.notifications.map(\.objectID)).count, 100)
        let fetches = model.fetchCount
        let message = Message(id: "incremental-push", time: 1_790_010_000, event: "message", topic: sub.topic!, message: "live push")
        _ = store.ingest(pushedMessage: message, baseUrl: sub.baseUrl!, topic: sub.topic!)
        XCTAssertEqual(model.notifications.first?.id, "incremental-push")
        XCTAssertEqual(model.fetchCount, fetches, "a push must not performFetch against loaded history")
        XCTAssertEqual(model.notifications.count, 100)
        model.search("sample 0:")
        XCTAssertEqual(model.notifications.map(\.time), [1_790_000_000], "search must run in the store, including unloaded pages")
        model.search("")
        model.loadOlder()
        model.loadOlder()
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 152)
        XCTAssertFalse(model.hasOlder)
    }

    func testPagingDoesNotNarrowReadCountsOrClearAllAndDeleteRemovesVisibleRowsImmediately() throws {
        store.clearPublisher = { _, done in done(.sent) }
        store.wakePublisher = { _, done in done() }
        store.notificationRemover = { _ in }
        let sub = try fixture(151)
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        for row in try store.context.fetch(request) { row.read = false }
        try store.context.save()
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        XCTAssertEqual(sub.unreadCount(), 151)
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(sub.unreadCount(), 0)
        XCTAssertTrue(model.notifications.allSatisfy(\.read))
        store.delete(notification: try XCTUnwrap(model.notifications.first))
        XCTAssertEqual(model.notifications.count, 50)
        XCTAssertFalse(model.notifications.contains { $0.isDeleted || $0.managedObjectContext == nil })
        let deletedAll = expectation(description: "all pages deleted")
        store.delete(allNotificationsFor: sub) { deletedAll.fulfill() }
        wait(for: [deletedAll], timeout: 10)
        XCTAssertTrue(model.notifications.isEmpty)
        XCTAssertEqual(try store.context.count(for: request), 0)
        XCTAssertEqual(sub.unreadCount(), 0)
    }


    func testCrossCoordinatorPushMergesIntoOpenPageWithoutRefetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var diskStores: [Store] = []
        defer { closeDiskStores(diskStores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.sqlite")
        // Distinct persistent-store coordinators model the app and NSE processes, not merely two
        // contexts whose saves automatically merge from the same parent.
        let app = Store(inMemory: true, storeURL: url)
        diskStores.append(app)
        app.saveNotificationRetention(.forever)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "cross-process")
        let model = NotificationsObservable(subscriptionID: sub.objectID, context: app.context)
        let fetches = model.fetchCount
        let writer = Store(inMemory: true, storeURL: url)
        diskStores.append(writer)
        writer.context.transactionAuthor = "ntfy.appex"
        let message = Message(id: "nse-writer", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "cross-process", message: "written by push")
        XCTAssertNotNil(writer.ingest(pushedMessage: message, baseUrl: "https://retention.example", topic: "cross-process"))
        let merged = expectation(description: "NSE history merged")
        app.mergeRemoteHistory { merged.fulfill() }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(model.notifications.map(\.id), ["nse-writer"])
        XCTAssertEqual(model.fetchCount, fetches, "the remote push must apply changed IDs without a window fetch")
        XCTAssertEqual(app.unreadCount(baseUrl: "https://retention.example", topic: "cross-process"), 1)

        let writerRow = try XCTUnwrap(writer.context.fetch(ntfy.Notification.fetchRequest()).first)
        writer.delete(notification: writerRow)
        let deleted = expectation(description: "NSE delete merged")
        app.mergeRemoteHistory { deleted.fulfill() }
        wait(for: [deleted], timeout: 10)
        XCTAssertTrue(model.notifications.isEmpty)
    }

    func testPruneCannotDeleteARowUpdatedByPushAfterItsFetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var diskStores: [Store] = []
        defer { closeDiskStores(diskStores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.sqlite")
        let app = Store(inMemory: true, storeURL: url)
        diskStores.append(app)
        app.saveNotificationRetention(.month)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "race")
        let now = Date()
        let row = ntfy.Notification(context: app.context)
        row.id = "old-version"
        row.sequenceID = "running-job"
        row.sequenceKey = "https://retention.example/race/running-job"
        row.time = Int64(now.timeIntervalSince1970) - 31 * 86_400
        row.message = "old"
        row.subscription = sub
        try app.context.save()
        let writer = Store(inMemory: true, storeURL: url)
        diskStores.append(writer)
        writer.context.transactionAuthor = "ntfy.appex"
        let file = dir.appendingPathComponent("incoming-attachment")
        try Data("new attachment".utf8).write(to: file)
        let pushed = expectation(description: "push updated the row during pruning")
        // WillSave fires after the candidates were fetched but before their delete commits.
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: app.retentionContext, queue: nil
        ) { _ in
            guard !app.retentionContext.deletedObjects.isEmpty else { return }
            writer.context.performAndWait {
                let message = Message(id: "new-version", time: Int64(now.timeIntervalSince1970), event: "message", topic: "race", message: "new", sequenceID: "running-job")
                XCTAssertNotNil(writer.ingest(pushedMessage: message, baseUrl: "https://retention.example", topic: "race"))
                writer.completeAttachmentDownload(notificationID: "new-version", localPath: file.path, resolvedType: nil, resolvedSize: 14)
            }
            pushed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let finished = expectation(description: "prune either safely aborts or excludes updated row")
        app.pruneNotifications(now: now) { _ in finished.fulfill() }
        wait(for: [pushed, finished], timeout: 10)
        writer.context.performAndWait {
            writer.hardRefresh()
            let rows = try? writer.context.fetch(ntfy.Notification.fetchRequest())
            XCTAssertEqual(rows?.compactMap(\.id), ["new-version"])
            XCTAssertEqual(rows?.first?.message, "new")
            XCTAssertEqual(rows?.first?.attachmentLocalPath, file.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEveryAndroidRetentionChoiceAndRecentPushGrace() throws {
        XCTAssertEqual(NotificationRetention.allCases.map(\.rawValue), [0, 1, 3, 7, 30, 90])
        for policy in NotificationRetention.allCases where policy != .forever {
            let isolated = Store(inMemory: true)
            isolated.saveNotificationRetention(policy)
            let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "policy")
            let now = Date()
            let message = Message(id: "old-but-arriving-now", time: Int64(now.timeIntervalSince1970) - policy.seconds - 1,
                                  event: "message", topic: "policy", message: "keep while NSE writes")
            XCTAssertNotNil(isolated.ingest(pushedMessage: message, baseUrl: sub.baseUrl!, topic: sub.topic!))
            let grace = expectation(description: "newly written push survives expiry")
            isolated.pruneNotifications(now: now) { result in
                XCTAssertEqual(try? result.get(), 0)
                grace.fulfill()
            }
            wait(for: [grace], timeout: 10)
            XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
            let expired = expectation(description: "message expires after ingestion grace")
            isolated.pruneNotifications(now: now.addingTimeInterval(3601)) { result in
                XCTAssertEqual(try? result.get(), 1)
                expired.fulfill()
            }
            wait(for: [expired], timeout: 10)
            XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        }
    }

    func testCommittedAttachmentCleanupSurvivesInterruptionAndProtectsUncommittedDownloads() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("download in flight".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // Represents a crash after committing the row deletion, before unlinking its old path.
        let entry = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: isolated.context)
        entry.setValue(file.path, forKey: "path")
        let missing = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: isolated.context)
        missing.setValue(file.path + ".missing", forKey: "path")
        try isolated.context.save()
        let now = Date()
        let protected = expectation(description: "uncommitted download survives")
        isolated.pruneNotifications(now: now) { _ in protected.fulfill() }
        wait(for: [protected], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 1,
                       "an already-missing file must not leave a permanent cleanup entry")
        let retried = expectation(description: "committed cleanup retried after grace")
        isolated.pruneNotifications(now: now.addingTimeInterval(3601)) { _ in retried.fulfill() }
        wait(for: [retried], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 0)
    }

    func testLateDownloadCompletionCleansFileAfterItsRowWasDeleted() throws {
        let isolated = Store(inMemory: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("late".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        isolated.completeAttachmentDownload(notificationID: "already-deleted", localPath: file.path, resolvedType: nil, resolvedSize: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testModel6HistoryMigratesWithoutDeletingRowsOrAttachmentPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var diskStores: [Store] = []
        defer { closeDiskStores(diskStores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        try autoreleasepool {
            let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
                .appendingPathComponent("Model 6.mom")
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let sub = NSManagedObject(entity: try XCTUnwrap(model.entitiesByName["Subscription"]), insertInto: context)
            sub.setValue("https://retention.example", forKey: "baseUrl")
            sub.setValue("migrate", forKey: "topic")
            let row = NSManagedObject(entity: try XCTUnwrap(model.entitiesByName["Notification"]), insertInto: context)
            row.setValue("model6-history", forKey: "id")
            row.setValue("history", forKey: "message")
            row.setValue(1, forKey: "time")
            row.setValue("/example/attachment", forKey: "attachmentLocalPath")
            row.setValue(sub, forKey: "subscription")
            try context.save()
            context.reset()
            try coordinator.remove(disk)
        }
        let migrated = Store(inMemory: true, storeURL: url)
        diskStores.append(migrated)
        let rows = try migrated.context.fetch(ntfy.Notification.fetchRequest())
        XCTAssertEqual(rows.compactMap(\.id), ["model6-history"])
        XCTAssertEqual(rows.first?.attachmentLocalPath, "/example/attachment")
        XCTAssertNil(rows.first?.storedAt)
        XCTAssertEqual(migrated.notificationRetention(), .forever)
    }


    func testFileAccessSerializesWritersAndPruning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shared-file")
        let firstEntered = expectation(description: "writer holds file lock")
        let firstExited = expectation(description: "writer finished")
        let secondEntered = expectation(description: "pruner acquired file lock after writer")
        let release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try AttachmentFileStore.withFileAccess(at: file) {
                    firstEntered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                    firstDone.signal()
                }
            } catch { XCTFail("writer lock: \(error)") }
            firstExited.fulfill()
        }
        wait(for: [firstEntered], timeout: 5)
        DispatchQueue.global().async {
            do {
                try AttachmentFileStore.withFileAccess(at: file) {
                    XCTAssertEqual(firstDone.wait(timeout: .now()), .success, "pruner cannot enter while writer still owns the directory lock")
                    secondEntered.fulfill()
                }
            } catch { XCTFail("pruner lock: \(error)") }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        wait(for: [firstExited, secondEntered], timeout: 5)
    }

    func testSameSecondPagingHasNoDuplicatesOrGaps() throws {
        let sub = try fixture(125)
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        let all = try store.context.fetch(request)
        all.forEach { $0.time = 1_790_000_000 }
        try store.context.save()
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        model.loadOlder()
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 125)
        XCTAssertEqual(Set(model.notifications.map(\.objectID)), Set(all.map(\.objectID)))
        XCTAssertFalse(model.hasOlder)
    }

    func testSequenceBookkeepingIsBoundedAndProtectsRecentWrites() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.month)
        let now = Date()
        for (key, time, stored) in [("expired", Int64(1), Optional<Date>.none),
                                    ("boundary", Int64(now.timeIntervalSince1970) - 120 * 86_400, nil),
                                    ("incoming", Int64(1), now)] {
            let state = NSEntityDescription.insertNewObject(forEntityName: "SequenceState", into: isolated.context)
            state.setValue(key, forKey: "key")
            state.setValue(key, forKey: "sequenceID")
            state.setValue(key, forKey: "eventID")
            state.setValue("message_delete", forKey: "event")
            state.setValue(time, forKey: "time")
            state.setValue(stored, forKey: "storedAt")
        }
        try isolated.context.save()
        let done = expectation(description: "bookkeeping expiry")
        isolated.pruneNotifications(now: now) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        let rows = try isolated.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SequenceState"))
        XCTAssertEqual(Set(rows.compactMap { $0.value(forKey: "key") as? String }), ["boundary", "incoming"])
    }

    func testScaleMeasurement10k() throws {
        let subscription = try fixture(10_000)
        let start = CFAbsoluteTimeGetCurrent()
        let model = NotificationsObservable(subscriptionID: subscription.objectID)
        // Read the same properties SwiftUI's rows need; don't time only an array of faults.
        let characters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let opened = CFAbsoluteTimeGetCurrent()
        model.refetch()
        let refreshedCharacters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let refreshed = CFAbsoluteTimeGetCurrent()
        let message = Message(id: "scale-push-\(UUID().uuidString)", time: 1_790_020_000, event: "message", topic: subscription.topic!, message: "new monitoring message")
        _ = store.ingest(pushedMessage: message, baseUrl: subscription.baseUrl!, topic: subscription.topic!)
        let pushCharacters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let end = CFAbsoluteTimeGetCurrent()
        print("RETENTION_SCALE rows=10000 published=\(model.notifications.count) open_ms=\((opened-start)*1000) remote_refresh_ms=\((refreshed-opened)*1000) push_ingest_and_publish_ms=\((end-refreshed)*1000) chars=\(characters)/\(refreshedCharacters)/\(pushCharacters)")
        XCTAssertGreaterThan(characters, 0)
    }

    func testFirstPageIsBoundedWith10kRows() throws {
        let subscription = try fixture(10_000)
        let model = NotificationsObservable(subscriptionID: subscription.objectID)
        XCTAssertEqual(model.notifications.count, 50, "Opening a topic must not publish its entire history")
        XCTAssertEqual(model.notifications.first?.time, 1_790_009_999)
    }
    func testMissingAttachmentParentAndNonDirectoryRetireQueueEntries() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let regularFile = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: regularFile)
        for path in [dir.appendingPathComponent("gone-container/file").path, regularFile.appendingPathComponent("file").path] {
            let entry = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: isolated.context)
            entry.setValue(path, forKey: "path")
        }
        try isolated.context.save()
        let done = expectation(description: "missing paths retired")
        isolated.pruneNotifications { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 0)
    }

    func testPresentedDeliveryEvidenceSurvivesRetentionAndReopening() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var diskStores: [Store] = []
        defer { closeDiskStores(diskStores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("review.sqlite")
        let isolated = Store(inMemory: true, storeURL: url)
        diskStores.append(isolated)
        isolated.saveNotificationRetention(.day)
        isolated.retentionContext.performAndWait {} // the save starts a prune; finish it before inserting rows
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "review")
        let now = Date()
        for i in 0..<3 {
            let row = ntfy.Notification(context: isolated.context)
            row.id = "review-\(i)"; row.message = "delivered"; row.subscription = sub
            row.time = Int64(now.timeIntervalSince1970) - Int64((i + 2) * 86_400)
            row.presented = true
        }
        try isolated.context.save()
        let before = isolated.presentedDeliveries()
        let done = expectation(description: "review rows expired")
        isolated.pruneNotifications(now: now) { result in
            XCTAssertEqual(try? result.get(), 3); done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        let reopened = Store(inMemory: true, storeURL: url)
        diskStores.append(reopened)
        XCTAssertEqual(reopened.presentedDeliveries().count, before.count)
        XCTAssertGreaterThanOrEqual(reopened.presentedDeliveries().days, 2)
    }

    func testPollDropsExpiredMessagesWithoutPresentationOrUnreadButAdvancesCursor() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.day)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "old-cache")
        let now = Int64(Date().timeIntervalSince1970)
        let old = Message(id: "expired-cache", time: now - 3 * 86_400, event: "message", topic: "old-cache", message: "old")
        let request = try XCTUnwrap(isolated.pollRequest(for: sub))
        XCTAssertEqual(isolated.save(notificationsFromMessages: [old], polledWith: request)?.count, 0)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        XCTAssertEqual(isolated.totalUnreadCount(), 0)
        XCTAssertEqual(sub.lastNotificationId, old.id, "discarded cache must not be polled forever")
        isolated.saveNotificationRetention(.forever)
        XCTAssertEqual(isolated.save(notificationsFromMessages: [old], polledWith: request)?.count, 1)
    }

    func testUnreadHeavyScaleMeasurement10k() throws {
        let sub = try fixture(10_000)
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        for row in try store.context.fetch(request) { row.read = false }
        try store.context.save()
        store.hardRefresh()
        let start = CFAbsoluteTimeGetCurrent()
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        store.setRead(true, forSubscription: sub)
        let opened = CFAbsoluteTimeGetCurrent()
        let materialized = store.context.registeredObjects.filter { $0.entity.name == "Notification" && !$0.isFault }.count
        store.markMostRecentUnread(subscription: sub)
        let marked = CFAbsoluteTimeGetCurrent()
        print("RETENTION_UNREAD_SCALE rows=10000 open_and_read_ms=\((opened-start)*1000) mark_newest_ms=\((marked-opened)*1000) materialized=\(materialized) published=\(model.notifications.count)")
        XCTAssertEqual(model.notifications.count, 50)
        XCTAssertLessThanOrEqual(materialized, 60, "opening must not materialize every unread row")
        let deletion = expectation(description: "10k history deleted off main")
        var largestChunk = 0
        let chunkObserver = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: store.retentionContext, queue: nil) { _ in
            largestChunk = max(largestChunk, self.store.retentionContext.deletedObjects.count)
            XCTAssertFalse(Thread.isMainThread, "history deletion must run on the private queue")
        }
        defer { NotificationCenter.default.removeObserver(chunkObserver) }
        let deleteStart = CFAbsoluteTimeGetCurrent()
        store.delete(allNotificationsFor: sub) { deletion.fulfill() }
        let enqueued = CFAbsoluteTimeGetCurrent()
        wait(for: [deletion], timeout: 30)
        let finished = CFAbsoluteTimeGetCurrent()
        print("RETENTION_UNREAD_DELETE rows=10000 enqueue_ms=\((enqueued-deleteStart)*1000) complete_ms=\((finished-deleteStart)*1000) largest_chunk=\(largestChunk)")
        XCTAssertGreaterThan(largestChunk, 0)
        XCTAssertLessThanOrEqual(largestChunk, 200)
        XCTAssertEqual(try store.context.count(for: request), 0)
    }

    func testRetentionSelectionStartsStoredAndCancelDoesNotDeleteThenConfirmPrunes() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "confirmation")
        let row = ntfy.Notification(context: isolated.context)
        row.id = "confirmation-old"; row.message = "old unread"; row.read = false
        row.time = Int64(Date().timeIntervalSince1970) - 10 * 86_400; row.subscription = sub
        try isolated.context.save()
        let selection = RetentionSelection(store: isolated)
        XCTAssertEqual(selection.policy, .forever)
        let counted = expectation(description: "count before asking")
        var observer = selection.$prompt.compactMap { $0 }.sink { prompt in
            XCTAssertEqual(prompt.count, 1); counted.fulfill()
        }
        selection.select(.day)
        wait(for: [counted], timeout: 10)
        observer.cancel()
        XCTAssertEqual(isolated.notificationRetention(), .forever)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
        selection.cancel()
        XCTAssertEqual(selection.policy, .forever)
        XCTAssertNil(selection.prompt)
        let askedAgain = expectation(description: "ask again after cancel")
        observer = selection.$prompt.compactMap { $0 }.sink { _ in askedAgain.fulfill() }
        selection.select(.day)
        wait(for: [askedAgain], timeout: 10)
        observer.cancel()
        selection.confirm(.day)
        XCTAssertEqual(isolated.notificationRetention(), .day)
        let pruned = expectation(description: "setting triggers pruning before queued maintenance")
        isolated.pruneNotifications { _ in pruned.fulfill() }
        wait(for: [pruned], timeout: 10)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        let reopenedSelection = RetentionSelection(store: isolated)
        XCTAssertEqual(reopenedSelection.policy, .day, "picker must start at persisted value")
    }

    func testSearchDebouncesAndMatchingLivePushDoesNotRefetch() throws {
        let sub = try fixture(151)
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        let initial = model.fetchCount
        model.scheduleSearch("back"); model.scheduleSearch("backup"); model.scheduleSearch("sample 0:")
        XCTAssertEqual(model.fetchCount, initial, "keystrokes must not synchronously scan history")
        let settled = expectation(description: "debounced search settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(model.fetchCount, initial + 1)
        XCTAssertEqual(model.notifications.count, 1)
        let push = Message(id: "matching-search", time: Int64(Date().timeIntervalSince1970), event: "message", topic: sub.topic!, message: "sample 0: new push")
        _ = store.ingest(pushedMessage: push, baseUrl: sub.baseUrl!, topic: sub.topic!)
        XCTAssertEqual(model.notifications.first?.id, push.id)
        XCTAssertEqual(model.fetchCount, initial + 1)
    }

    func testStoreInitializationDoesNotNeedTheMainQueue() {
        let done = DispatchSemaphore(value: 0)
        var created: Store?
        let cleaned = expectation(description: "background init fixture closed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let isolated = Store(inMemory: false, storeURL: dir.appendingPathComponent("init.sqlite"))
            created = isolated
            done.signal()
            DispatchQueue.main.async {
                self.closeDiskStores([isolated])
                try? FileManager.default.removeItem(at: dir)
                cleaned.fulfill()
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "init must not wait on the blocked main queue")
        XCTAssertEqual(created?.context.automaticallyMergesChangesFromParent, true, "first main-thread use must be configured before its queued setup runs")
        XCTAssertEqual(created?.context.transactionAuthor, "ntfy")
        wait(for: [cleaned], timeout: 10)
    }

    func testPagingIndexIsInTheShippedModel() throws {
        let entity = try XCTUnwrap(store.container.managedObjectModel.entitiesByName["Notification"])
        let index = try XCTUnwrap(entity.indexes.first { $0.name == "notificationPage" })
        XCTAssertEqual(index.elements.compactMap { $0.property?.name }, ["subscription", "time", "id"])
    }

    func testNSEHistoryTrimDoesNotNeedToPruneMessageRows() throws {
        let isolated = Store(inMemory: true)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "nse-trim")
        isolated.save(notificationsFromMessages: [Message(id: "keep-history-row", time: 1, event: "message", topic: sub.topic!, message: "keep")], withSubscription: sub)
        let trimmed = expectation(description: "extension maintenance trimmed history")
        isolated.trimPersistentHistory(now: Date().addingTimeInterval(8 * 86_400)) { trimmed.fulfill() }
        wait(for: [trimmed], timeout: 10)
        let result = try isolated.context.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)) as? NSPersistentHistoryResult
        XCTAssertTrue((result?.result as? [NSPersistentHistoryTransaction] ?? []).isEmpty)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
    }

    func testLocalHistoryDoesNotBroadcastAnExtensionChange() {
        let isolated = Store(inMemory: true)
        _ = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "own-history")
        var broadcasts = 0
        let observer = NotificationCenter.default.addObserver(forName: Store.didChangeRemotely, object: nil, queue: nil) { _ in broadcasts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let merged = expectation(description: "own history consumed")
        isolated.mergeRemoteHistory { merged.fulfill() }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(broadcasts, 0)
    }

    func testBulkReadKeepsConcurrentPushUnreadAndHistoryMergeBounded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var diskStores: [Store] = []
        defer { closeDiskStores(diskStores); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("read-race.sqlite")
        let app = Store(inMemory: true, storeURL: url)
        diskStores.append(app)
        app.saveNotificationRetention(.forever)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "read-race")
        for i in 0..<1000 {
            let row = ntfy.Notification(context: app.context)
            row.id = "read-race-\(i)"; row.time = Int64(i); row.message = "old unread"
            row.read = false; row.subscription = sub
        }
        try app.context.save(); app.hardRefresh()
        let writer = Store(inMemory: true, storeURL: url)
        diskStores.append(writer)
        writer.context.transactionAuthor = "ntfy.appex"
        let model = NotificationsObservable(subscriptionID: sub.objectID, context: app.context)
        let pending = Preference(context: app.context); pending.key = "pending-read-race"; pending.value = "1"
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: app.context, queue: nil) { _ in
            let message = Message(id: "new-during-read", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "read-race", message: "new unread")
            XCTAssertNotNil(writer.ingest(pushedMessage: message, baseUrl: sub.baseUrl!, topic: sub.topic!))
        }
        app.notificationRemover = { _ in }; app.topicNotificationRemover = { _, _, _, _ in }
        app.clearPublisher = { _, done in done(.sent) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        app.clearPacer.schedule = { delay, work in clock += delay; work() }
        app.clearPacer.now = { clock }
        app.setRead(true, forSubscription: sub)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(app.totalUnreadCount(), 1, "push committed after the read action began stays unread")
        let merged = expectation(description: "read and incoming push history merged")
        app.mergeRemoteHistory { merged.fulfill() }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(model.notifications.first?.id, "new-during-read")
        XCTAssertEqual(model.notifications.first?.read, false)
        XCTAssertLessThanOrEqual(app.context.registeredObjects.filter { $0.entity.name == "Notification" && !$0.isFault }.count, 65)
    }


    func testPruneKeepsPollCursorAndJoinedRefreshDoesNotReviveExpiredHistory() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "join-after-prune")
        let now = Date()
        let old = Message(id: "pruned-cursor", time: Int64(now.timeIntervalSince1970) - 180 * 86_400,
                          event: "message", topic: sub.topic!, message: "expired")
        isolated.save(notificationFromMessage: old, withSubscription: sub)
        let row = try XCTUnwrap(try isolated.context.fetch(ntfy.Notification.fetchRequest()).first { $0.id == old.id })
        row.storedAt = now.addingTimeInterval(-7200)
        let states = try isolated.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SequenceState"))
        states.forEach { $0.setValue(now.addingTimeInterval(-7200), forKey: "storedAt") }
        let pref = try XCTUnwrap(isolated.context.fetch(Preference.fetchRequest()).first { $0.key == Store.retentionPreferenceKey })
        pref.value = String(NotificationRetention.day.rawValue)
        try isolated.context.save()
        let cursorTime = sub.lastEventTime
        let original = try XCTUnwrap(isolated.pollRequest(for: sub))
        XCTAssertEqual(original.since, old.id)
        var clears = 0, wakes = 0
        isolated.clearPublisher = { _, done in clears += 1; done(.sent) }
        isolated.wakePublisher = { _, done in wakes += 1; done() }
        let coordinator = PollCoordinator(defaults: nil, now: { now })
        var manager = SubscriptionManager(store: isolated, polling: coordinator)
        var fetches = 0
        var reply: (([Message]?, Error?) -> Void)?
        manager.fetch = { request, done in
            fetches += 1; XCTAssertEqual(request.since, old.id); reply = done
        }
        var outcomes: [PollOutcome] = []
        manager.pollWithOutcome(sub, automaticList: true, presenting: true) { outcomes.append($0) }
        let pruned = expectation(description: "prune while joined request is in flight")
        isolated.pruneNotifications(now: now) { result in
            XCTAssertEqual(try? result.get(), 1); pruned.fulfill()
        }
        wait(for: [pruned], timeout: 10)
        XCTAssertEqual(isolated.pollRequest(for: sub)?.since, old.id, "expiry must not reset since to all")
        XCTAssertEqual(sub.lastEventTime, cursorTime)
        XCTAssertNil(isolated.reconciliationRequest(after: original))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "SequenceState")), 0)
        manager.pollWithOutcome(sub, presenting: true) { outcomes.append($0) }
        XCTAssertEqual(fetches, 1, "a prune must not discard PollCoordinator's in-flight join")
        let fresh = Message(id: "fresh-after-prune", time: Int64(now.timeIntervalSince1970),
                            event: "message", topic: sub.topic!, message: "new")
        try XCTUnwrap(reply)([old, fresh], nil)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(outcomes.flatMap(\.newMessages).map(\.id), [fresh.id], "joined presenters get one fresh alert only")
        XCTAssertEqual(isolated.totalUnreadCount(), 1)
        XCTAssertNil(try isolated.context.fetch(ntfy.Notification.fetchRequest()).first { $0.id == old.id })
        XCTAssertEqual(isolated.pollRequest(for: sub)?.since, fresh.id)
        XCTAssertTrue(DeliveryHealthMonitor.shared.healthy(keys: [sub.objectID.uriRepresentation().absoluteString]))
        var skipped = false
        manager.pollWithOutcome(sub, automaticList: true) { skipped = !$0.attempted }
        XCTAssertTrue(skipped, "retention must not reset the automatic list minimum interval")
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(clears, 0, "local expiry must not invoke ClearPacer")
        XCTAssertEqual(wakes, 0)
    }

    func testPruneInvalidatesTopicSummariesAndBadgeWithoutChangingPushStatus() throws {
        let sub = try fixture(60)
        let now = Date()
        let rows = try store.context.fetch(ntfy.Notification.fetchRequest()).filter { $0.subscription == sub }
        for (index, row) in rows.enumerated() {
            row.time = Int64(now.timeIntervalSince1970) - (index < 55 ? 3 * 86_400 : 3600)
            row.read = false; row.storedAt = now.addingTimeInterval(-7200)
        }
        sub.fcmSubscribed = false
        try store.context.save()
        let baseline = store.totalUnreadCount() - 60
        let topics = SubscriptionsObservable()
        XCTAssertEqual(topics.summaries[sub.objectID]?.unread, 60) // warm the actual row-summary cache
        let page = NotificationsObservable(subscriptionID: sub.objectID)
        let pref = try XCTUnwrap(store.context.fetch(Preference.fetchRequest()).first { $0.key == Store.retentionPreferenceKey })
        pref.value = String(NotificationRetention.day.rawValue)
        try store.context.save()
        defer { store.saveNotificationRetention(.forever) }
        let key = sub.objectID.uriRepresentation().absoluteString
        DeliveryHealthMonitor.shared.record(key: key, failure: .unauthorized)
        let pageMerged = expectation(description: "prune reaches the published page")
        let summaryMerged = expectation(description: "prune invalidates warmed topic summaries")
        var sawPage = false, sawSummary = false
        let pageChanges = page.$notifications.sink { rows in
            if rows.count == 5 && !sawPage { sawPage = true; pageMerged.fulfill() }
        }
        let summaryChanges = topics.objectWillChange.sink {
            if topics.summaries[sub.objectID]?.unread == 5 && !sawSummary {
                sawSummary = true; summaryMerged.fulfill()
            }
        }
        defer { pageChanges.cancel(); summaryChanges.cancel() }
        let done = expectation(description: "prune summary and page merge")
        store.pruneNotifications(now: now) { result in
            XCTAssertEqual(try? result.get(), 55); done.fulfill()
        }
        wait(for: [done, pageMerged, summaryMerged], timeout: 10)
        store.context.processPendingChanges()
        XCTAssertEqual(topics.summaries[sub.objectID]?.total, 5)
        XCTAssertEqual(topics.summaries[sub.objectID]?.unread, 5)
        XCTAssertEqual(store.totalUnreadCount(), baseline + 5)
        XCTAssertEqual(page.notifications.count, 5)
        XCTAssertTrue(topics.subscriptions.contains { $0.objectID == sub.objectID && !$0.fcmSubscribed },
                      "Notification status must still count this topic as waiting for push")
        XCTAssertEqual(DeliveryHealthMonitor.shared.topics[key]?.failure, .unauthorized,
                       "expiry is not evidence that a failed delivery recovered")
        let content = UNMutableNotificationContent()
        content.modify(message: Message(id: "badge-probe", time: Int64(now.timeIntervalSince1970),
                                       event: "message", topic: sub.topic!, message: "probe"), baseUrl: sub.baseUrl!)
        XCTAssertEqual(content.badge?.intValue, baseline + 5, "the NSE content path must use the post-prune unread total")
    }


    func testExtensionSaveAndSameSecondReconciliationAfterPruneKeepTheOpenPageCurrent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var disks: [Store] = []
        defer { closeDiskStores(disks); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nse-prune.sqlite")
        let app = Store(inMemory: true, storeURL: url); disks.append(app)
        app.saveNotificationRetention(.forever)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "nse-after-prune")
        let now = Date()
        let old = Message(id: "old-job", time: Int64(now.timeIntervalSince1970) - 3 * 86_400,
                          event: "message", topic: sub.topic!, message: "old", sequenceID: "job")
        app.save(notificationFromMessage: old, withSubscription: sub)
        let row = try XCTUnwrap(app.context.fetch(ntfy.Notification.fetchRequest()).first)
        row.storedAt = now.addingTimeInterval(-7200)
        let pref = try XCTUnwrap(app.context.fetch(Preference.fetchRequest()).first { $0.key == Store.retentionPreferenceKey })
        pref.value = String(NotificationRetention.day.rawValue)
        try app.context.save()
        let writer = Store(inMemory: true, storeURL: url); disks.append(writer)
        writer.context.transactionAuthor = "ntfy.appex"
        writer.allowsKeyDerivation = false // same restriction as the NSE
        let model = NotificationsObservable(subscriptionID: sub.objectID, context: app.context)
        let pruned = expectation(description: "old sequence row pruned")
        app.pruneNotifications(now: now) { result in XCTAssertEqual(try? result.get(), 1); pruned.fulfill() }
        wait(for: [pruned], timeout: 10)
        app.context.processPendingChanges()
        XCTAssertTrue(model.notifications.isEmpty)
        let fetches = model.fetchCount
        var clears = 0
        writer.clearPublisher = { _, done in clears += 1; done(.sent) }
        let fresh = Message(id: "new-job", time: Int64(now.timeIntervalSince1970),
                            event: "message", topic: sub.topic!, message: "new", sequenceID: "job")
        guard case .stored = writer.ingest(pushedMessage: fresh, baseUrl: sub.baseUrl!, topic: sub.topic!) else {
            return XCTFail("the NSE save path must accept the new version after local expiry")
        }
        let control = Message(id: "clear-job", time: fresh.time, event: "message_clear", topic: sub.topic!, sequenceID: "job")
        guard case .reconcile(let request) = writer.ingest(pushedMessage: control, baseUrl: sub.baseUrl!, topic: sub.topic!) else {
            return XCTFail("an ambiguous same-second control must retain the NSE reconciliation path")
        }
        XCTAssertNil(request.since)
        XCTAssertEqual(writer.save(notificationsFromMessages: [fresh, control], polledWith: request)?.count, 0)
        let merged = expectation(description: "NSE save and reconciliation merged")
        app.mergeRemoteHistory { merged.fulfill() }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(model.notifications.map(\.id), [fresh.id])
        XCTAssertTrue(try XCTUnwrap(model.notifications.first).read)
        XCTAssertEqual(model.fetchCount, fetches, "merged NSE writes must not refetch the page")
        XCTAssertEqual(app.totalUnreadCount(), 0)
        XCTAssertEqual(app.pollRequest(for: sub)?.since, control.id)
        XCTAssertEqual(clears, 0, "remote reconcile controls never echo a server clear")
    }

}

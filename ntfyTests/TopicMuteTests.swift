import XCTest
import CoreData
import UserNotifications
@testable import ntfy

final class TopicMuteTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_512_000)

    func testMuteDeadlineBoundaryAndUntilResumed() {
        XCTAssertFalse(TopicMute.isMuted(until: nil, now: now))
        XCTAssertFalse(TopicMute.isMuted(until: now, now: now))
        XCTAssertFalse(TopicMute.isMuted(until: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(TopicMute.isMuted(until: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(TopicMute.isMuted(until: .distantFuture, now: now))
        XCTAssertNil(TopicMute.status(until: now, now: now))
        XCTAssertEqual(TopicMute.status(until: .distantFuture, now: now), "Notifications muted until resumed")
    }

    func testAndroidDurationsAndTomorrowAt0830AcrossDaylightSaving() throws {
        for (duration, seconds) in [(TopicMuteDuration.minutes30, 1800), (.hour1, 3600), (.hours2, 7200), (.hours8, 28800)] {
            XCTAssertEqual(duration.deadline(now: now).timeIntervalSince(now), Double(seconds))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (month, day) in [(3, 7), (10, 31), (12, 31)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 45)))
            let deadline = TopicMuteDuration.tomorrow.deadline(now: date, calendar: calendar)
            let parts = calendar.dateComponents([.hour, .minute, .second], from: deadline)
            XCTAssertEqual(parts.hour, 8); XCTAssertEqual(parts.minute, 30); XCTAssertEqual(parts.second, 0)
            XCTAssertEqual(calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: deadline)).day, 1)
        }
    }

    func testMuteIsScopedByServerAndTopicAndSavedOutsideTheViewContext() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "noise")
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
        try store.setTopicMute(until: now.addingTimeInterval(10), subscription: sub)
        XCTAssertTrue(store.isTopicMuted(baseUrl: "https://mute.example/", topic: "noise", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: "https://other.example", topic: "noise", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: "https://mute.example", topic: "other", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now.addingTimeInterval(10)))
        try store.setTopicMute(until: nil, subscription: sub)
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
    }

    func testEveryPriorityAndCriticalOptInIsQuietWhileHistoryAndBadgeRemain() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "priority-\(UUID().uuidString)")
        let oldCritical = store.getCriticalAlertsEnabled()
        let oldAuthorized = Store.getCriticalAlertsAuthorized()
        defer {
            store.saveCriticalAlertsEnabled(oldCritical)
            Store.saveCriticalAlertsAuthorized(oldAuthorized)
            store.context.delete(sub); try? store.context.save()
        }
        store.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(true)
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        for priority in 1...5 {
            let message = Message(id: "mute-p\(priority)", time: Int64(Date().timeIntervalSince1970), event: "message", topic: sub.topic!, message: "Keep muted history", priority: Int16(priority))
            _ = store.save(notificationsFromMessages: [message], withSubscription: sub)
            let content = UNMutableNotificationContent()
            content.modify(message: message, baseUrl: sub.baseUrl!)
            XCTAssertNil(content.sound, "priority \(priority) must not make a sound")
            XCTAssertEqual(content.interruptionLevel, .passive)
            XCTAssertEqual(content.relevanceScore, 0)
            XCTAssertEqual(content.body, "Keep muted history")
            XCTAssertEqual(content.badge?.intValue, store.totalUnreadCount())
        }
        XCTAssertEqual(sub.notificationCount(), 5)
        XCTAssertEqual(sub.unreadCount(), 5)
        try store.setTopicMute(until: nil, subscription: sub)
        let content = UNMutableNotificationContent()
        content.modify(message: Message(id: "resumed", time: 1, event: "message", topic: sub.topic!, priority: 4), baseUrl: sub.baseUrl!)
        XCTAssertNotNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }

    func testFallbackAndReplayContentsAreQuietAndExpiryRestoresNormalMapping() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "fallback")
        try store.setTopicMute(until: now.addingTimeInterval(1), subscription: sub)
        for text in ["New message", "Couldn't fetch notification", "Encrypted message", "Notification state synchronized"] {
            let content = UNMutableNotificationContent()
            content.body = text; content.sound = .defaultCritical; content.interruptionLevel = .critical; content.badge = 42
            content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now)
            XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
            XCTAssertEqual(content.badge, 42); XCTAssertEqual(content.body, text)
        }
        let content = UNMutableNotificationContent()
        let message = Message(id: "expired", time: 1, event: "message", topic: sub.topic!, priority: 4)
        content.configureInterruption(message: message)
        content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now)
        XCTAssertNil(content.sound)
        // A fetch/attachment crossing the deadline rechecks the policy at final delivery.
        content.configureInterruption(message: message)
        content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now.addingTimeInterval(1))
        XCTAssertNotNil(content.sound); XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }

    func testPollHashRawTopicFallbackAndMalformedMessagesUseSameMuteDecision() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "hash-muted")
        try store.setTopicMute(until: now.addingTimeInterval(10), subscription: sub)
        for topic in [sub.topic!, sub.urlHash()] {
            let info: [AnyHashable: Any] = ["topic": topic, "event": "poll_request", "base_url": "https://mute.example/"]
            XCTAssertTrue(store.isNotificationMuted(userInfo: info, now: now))
            XCTAssertFalse(store.isNotificationMuted(userInfo: info, now: now.addingTimeInterval(10)))
            let content = UNMutableNotificationContent()
            content.userInfo = info; content.sound = .default; content.interruptionLevel = .timeSensitive
            content.applyTopicMute(store: store, now: now)
            XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
        }
        // Even without a parsable Message, routing metadata still protects the NSE fallback.
        XCTAssertTrue(store.isNotificationMuted(userInfo: ["topic": sub.topic!, "base_url": sub.baseUrl!], now: now))
        XCTAssertFalse(store.isNotificationMuted(userInfo: ["topic": sub.topic!, "base_url": "https://other.example"], now: now))
    }

    func testModel7MigrationPreservesHistoryAndMutePersistsAcrossTwoProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upgrade118.sqlite")
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("Model 7.mom")))
        let old = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let disk = try old.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = old
        let sub = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: context)
        sub.setValue("https://mute.example", forKey: "baseUrl"); sub.setValue("upgrade", forKey: "topic")
        sub.setValue("My alerts", forKey: "customDisplayName"); sub.setValue(true, forKey: "pinned")
        let row = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: context)
        row.setValue("before118", forKey: "id"); row.setValue("Retain history", forKey: "message")
        row.setValue(3, forKey: "priority"); row.setValue(false, forKey: "read"); row.setValue(sub, forKey: "subscription")
        try context.save(); context.reset(); try old.remove(disk)
        let app = Store(inMemory: true, storeURL: url)
        let migrated = try XCTUnwrap(app.getSubscriptions()?.first)
        XCTAssertNil(migrated.mutedUntil)
        XCTAssertEqual(migrated.customDisplayName, "My alerts"); XCTAssertTrue(migrated.pinned)
        XCTAssertEqual(migrated.notificationCount(), 1); XCTAssertEqual(migrated.unreadCount(), 1)
        let nse = Store(inMemory: true, storeURL: url)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        try app.setTopicMute(until: .distantFuture, subscription: migrated)
        XCTAssertTrue(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        try app.setTopicMute(until: now.addingTimeInterval(1), subscription: migrated)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now.addingTimeInterval(1)))
        try app.setTopicMute(until: nil, subscription: migrated)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        for store in [nse, app] {
            store.context.reset()
            for disk in store.container.persistentStoreCoordinator.persistentStores { try store.container.persistentStoreCoordinator.remove(disk) }
        }
    }

    func testEveryLegacyModelMigratesHistoryAttachmentsAndSharedMute() throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
        let currentModel = Store.shared.container.managedObjectModel
        let versions = ["Model"] + (2...7).map { "Model \($0)" }
        for version in versions {
            let failuresBefore = testRun?.failureCount ?? 0
            do {
                try XCTContext.runActivity(named: "\(version) to current model") { _ in
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("legacy.sqlite")
                    var stores: [Store] = []
                    defer {
                        for store in stores.reversed() {
                            store.context.reset()
                            for disk in store.container.persistentStoreCoordinator.persistentStores {
                                try? store.container.persistentStoreCoordinator.remove(disk)
                            }
                        }
                        try? FileManager.default.removeItem(at: directory)
                    }
                    let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent(version + ".mom")))
                    let hasReadState = oldModel.entitiesByName["Notification"]?.attributesByName["read"] != nil
                    // Fail this case if Core Data cannot infer a lightweight mapping. No custom mapping.
                    _ = try NSMappingModel.inferredMappingModel(forSourceModel: oldModel, destinationModel: currentModel)
                    try autoreleasepool {
                        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
                        let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
                        defer { try? coordinator.remove(disk) }
                        let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
                        writer.persistentStoreCoordinator = coordinator
                        for index in 0..<2 {
                            // Use generic instances without changing the historical model or its hashes.
                            let sub = NSManagedObject(entity: try XCTUnwrap(oldModel.entitiesByName["Subscription"]), insertInto: writer)
                            sub.setValue("https://mute.example", forKey: "baseUrl")
                            sub.setValue("legacy-\(index)", forKey: "topic")
                            sub.setValue("Saved topic \(index)", forKey: "customDisplayName")
                            sub.setValue("legacy-id-\(index)", forKey: "lastNotificationId")
                            let row = NSManagedObject(entity: try XCTUnwrap(oldModel.entitiesByName["Notification"]), insertInto: writer)
                            let fields: [String: Any] = [
                                "id": "legacy-id-\(index)", "title": "Saved title \(index)",
                                "message": "Saved body \(index)", "time": Int64(1_700_000_000 + index), "priority": Int16(3 + index),
                                "attachmentLocalPath": "/saved/legacy-\(index).txt", "attachmentName": "legacy-\(index).txt",
                                "attachmentType": "text/plain", "attachmentUrl": "https://mute.example/file/legacy-\(index).txt",
                                "attachmentSize": Int64(4096 + index), "attachmentExpires": Int64(2_000_000_000 + index),
                                "attachmentProgress": Int16(100)
                            ]
                            for (key, value) in fields { row.setValue(value, forKey: key) }
                            if hasReadState { row.setValue(index == 0, forKey: "read") }
                            row.setValue(sub, forKey: "subscription")
                        }
                        try writer.save()
                        writer.reset()
                    }
                    let oldMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
                    XCTAssertTrue(oldModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: oldMetadata))

                    // Exercise Store's production automatic/inferred migration options on the old file.
                    let app = Store(inMemory: true, storeURL: url)
                    stores.append(app)
                    XCTAssertEqual(app.container.persistentStoreCoordinator.persistentStores.count, 1)
                    _ = try XCTUnwrap(app.container.persistentStoreCoordinator.persistentStores.first)
                    let migratedMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
                    XCTAssertTrue(currentModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: migratedMetadata))
                    let subscriptions = try XCTUnwrap(app.getSubscriptions())
                    XCTAssertEqual(subscriptions.count, 2)
                    let messages = try app.context.fetch(NSFetchRequest<ntfy.Notification>(entityName: "Notification"))
                    XCTAssertEqual(messages.count, 2)
                    for index in 0..<2 {
                        let sub = try XCTUnwrap(subscriptions.first { $0.topic == "legacy-\(index)" })
                        XCTAssertEqual(sub.baseUrl, "https://mute.example")
                        XCTAssertEqual(sub.customDisplayName, "Saved topic \(index)")
                        XCTAssertEqual(sub.lastNotificationId, "legacy-id-\(index)")
                        XCTAssertNil(sub.mutedUntil)
                        XCTAssertEqual(sub.notificationCount(), 1)
                        let row = try XCTUnwrap(messages.first { $0.id == "legacy-id-\(index)" })
                        XCTAssertEqual(row.subscription, sub)
                        XCTAssertEqual(row.title, "Saved title \(index)")
                        XCTAssertEqual(row.message, "Saved body \(index)")
                        XCTAssertEqual(row.time, Int64(1_700_000_000 + index))
                        XCTAssertEqual(row.priority, Int16(3 + index))
                        // Models 1 and 2 predate read state; their rows receive the current true default.
                        XCTAssertEqual(row.read, hasReadState ? index == 0 : true)
                        XCTAssertEqual(sub.unreadCount(), hasReadState && index == 1 ? 1 : 0)
                        XCTAssertEqual(row.attachmentLocalPath, "/saved/legacy-\(index).txt")
                        XCTAssertEqual(row.attachmentName, "legacy-\(index).txt")
                        XCTAssertEqual(row.attachmentType, "text/plain")
                        XCTAssertEqual(row.attachmentUrl, "https://mute.example/file/legacy-\(index).txt")
                        XCTAssertEqual(row.attachmentSize, Int64(4096 + index))
                        XCTAssertEqual(row.attachmentExpires, Int64(2_000_000_000 + index))
                        XCTAssertEqual(row.attachmentProgress, 100)
                    }
                    let nse = Store(inMemory: true, storeURL: url)
                    stores.append(nse)
                    let sub = try XCTUnwrap(subscriptions.first { $0.topic == "legacy-0" })
                    XCTAssertFalse(nse.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
                    let deadline = now.addingTimeInterval(120)
                    try app.setTopicMute(until: deadline, subscription: sub)
                    XCTAssertTrue(nse.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
                    XCTAssertEqual(nse.getSubscription(baseUrl: sub.baseUrl!, topic: sub.topic!)?.mutedUntil, deadline)
                    XCTAssertFalse(nse.isTopicMuted(baseUrl: sub.baseUrl!, topic: "legacy-1", now: now))
                    XCTAssertFalse(nse.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: deadline))
                }
                if testRun?.failureCount == failuresBefore {
                    print("MUTE_LEGACY_MIGRATION_PASS \(version)")
                }
            } catch {
                XCTFail("\(version) lightweight migration failed: \(error)")
            }
        }
    }
}

/// Uses only 1.18 APIs so these tests compile and fail as assertions on main.
final class MuteMainRegressionTests: XCTestCase {
    func testPersistedMuteDeadlineExists() {
        XCTAssertNotNil(Store.shared.container.managedObjectModel.entitiesByName["Subscription"]?.attributesByName["mutedUntil"], "1.18 has no durable per-topic mute state")
    }
    func testMutedPriorityFiveDoesNotAlertAndStillStoresHistory() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "main-red")
        defer { store.context.delete(sub); try? store.context.save() }
        if sub.entity.attributesByName["mutedUntil"] != nil {
            sub.setValue(Date.distantFuture, forKey: "mutedUntil"); try store.context.save()
        }
        let msg = Message(id: "mute-main-red", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "main-red", message: "Quiet history", priority: 5)
        _ = store.save(notificationsFromMessages: [msg], withSubscription: sub)
        let content = UNMutableNotificationContent()
        content.modify(message: msg, baseUrl: sub.baseUrl!)
        XCTAssertNil(content.sound, "muted priority 5 must not play sound")
        XCTAssertEqual(content.interruptionLevel, .passive, "muted priority 5 must not bypass Focus")
        XCTAssertEqual(sub.notificationCount(), 1)
        XCTAssertEqual(content.body, "Quiet history")
    }
}

/// Compiles the actual extension source into the test bundle. This exercises its final
/// delivery gate, without pretending that a simulator APNs push launched an NSE process.
final class TopicMuteNSETests: XCTestCase {
    func testActualNSESuccessAndDecodeFallbackStayQuietAtPriorityFive() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "nse-success")
        defer { store.context.delete(sub); try? store.context.save() }
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        for malformed in [false, true] {
            let service = NotificationService()
            let content = UNMutableNotificationContent()
            content.body = "Incoming fallback"; content.sound = .defaultCritical; content.interruptionLevel = .critical
            if malformed {
                content.userInfo = ["base_url": sub.baseUrl!, "topic": sub.topic!]
            } else {
                content.userInfo = Message(id: "nse-stored", time: Int64(Date().timeIntervalSince1970), event: "message", topic: sub.topic!, message: "NSE stored muted history", priority: 5).toUserInfo()
                content.userInfo["base_url"] = sub.baseUrl!
            }
            let done = expectation(description: "actual NSE handler \(malformed)")
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                service.didReceive(request) { output in
                    XCTAssertNil(output.sound); XCTAssertEqual(output.interruptionLevel, .passive)
                    XCTAssertEqual(output.body, malformed ? "Incoming fallback" : "NSE stored muted history")
                    done.fulfill()
                }
            }
            wait(for: [done], timeout: 8)
        }
        XCTAssertEqual(sub.notificationCount(), 1)
        XCTAssertEqual(sub.unreadCount(), 1)
    }

    func testActualNSEHashedPollExpiryAndFailureUseQuietFallbackExactlyOnce() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "http://127.0.0.1:1", topic: "nse-fallback")
        defer { store.context.delete(sub); try? store.context.save() }
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        let expectedTopic = sub.topic!
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.sound = .default; content.interruptionLevel = .timeSensitive
        content.userInfo = ["id": "nse-poll", "time": "1", "event": "poll_request", "topic": sub.urlHash(), "poll_id": "nse-poll", "base_url": sub.baseUrl!]
        let request = UNNotificationRequest(identifier: "nse-poll", content: content, trigger: nil)
        let done = expectation(description: "one final delivery")
        done.assertForOverFulfill = true
        service.didReceive(request) { output in
            XCTAssertNil(output.sound); XCTAssertEqual(output.interruptionLevel, .passive)
            XCTAssertEqual(output.title, expectedTopic)
            done.fulfill()
        }
        // This is the real expiry entry point while the fetch is still pending.
        service.serviceExtensionTimeWillExpire()
        wait(for: [done], timeout: 8)
    }
}

import XCTest
import CoreData
import UserNotifications
@testable import ntfy

final class SubscriptionDateTests: XCTestCase {
    private let store = Store.shared
    private let base = "https://subscription-date.example"

    override func tearDown() {
        for row in store.getSubscriptions() ?? [] where row.baseUrl == base {
            store.context.delete(row)
        }
        try? store.context.save()
        super.tearDown()
    }

    private func date(_ row: NSManagedObject) throws -> Date? {
        let attribute = try XCTUnwrap(row.entity.attributesByName["subscribedAt"], "Subscription must persist its creation time")
        XCTAssertEqual(attribute.attributeType, .dateAttributeType)
        XCTAssertTrue(attribute.isOptional, "Legacy rows have no known creation time")
        return row.value(forKey: "subscribedAt") as? Date
    }

    func testNewSubscriptionRecordsLocalCreationTimeAndPreservesItThroughEditsAndHistory() throws {
        let before = Date()
        let row = store.saveSubscription(baseUrl: base, topic: "new")
        let created = try XCTUnwrap(date(row))
        XCTAssertGreaterThanOrEqual(created, before)
        XCTAssertLessThanOrEqual(created, Date())
        store.updateSubscription(subscription: row, displayName: "Renamed")
        store.setPinned(true, forSubscription: row)
        store.save(notificationsFromMessages: [Message(id: "old-history", time: 1, event: "message", topic: "new", message: "Older than subscription")], withSubscription: row)
        store.context.refresh(row, mergeChanges: false)
        XCTAssertEqual(try date(row), created, "An edit or old server message cannot redefine the subscription date")
        XCTAssertEqual(row.notificationCount(), 1)
    }

    func testBackgroundCreationRecordsDateOnTheStoreQueue() throws {
        let before = Date()
        let done = expectation(description: "background subscription saved")
        DispatchQueue.global().async {
            _ = self.store.saveSubscription(baseUrl: self.base, topic: "background")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let row = try XCTUnwrap(store.getSubscription(baseUrl: base, topic: "background"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(date(row)), before)
    }

    func testResubscribingGetsANewDate() throws {
        let row = store.saveSubscription(baseUrl: base, topic: "again")
        _ = try date(row)
        row.setValue(Date(timeIntervalSince1970: 1), forKey: "subscribedAt")
        store.context.delete(row)
        try store.context.save()
        let before = Date()
        let replacement = store.saveSubscription(baseUrl: base, topic: "again")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(date(replacement)), before)
    }

    func testLegacyDateStaysUnknownAfterEditsAndMessages() throws {
        let row = store.saveSubscription(baseUrl: base, topic: "legacy")
        _ = try date(row)
        row.setValue(nil, forKey: "subscribedAt")
        try store.context.save()
        store.updateSubscription(subscription: row, displayName: "Existing topic")
        store.save(notificationsFromMessages: [Message(id: "legacy-message", time: 1, event: "message", topic: "legacy", message: "Not creation evidence")], withSubscription: row)
        store.context.refresh(row, mergeChanges: false)
        XCTAssertNil(try date(row))
    }

    func testAllThreeBundlesShipTheSameOptionalDateModelAndEveryOldVersion() throws {
        let appURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        for (name, url) in [("app", appURL), ("nse", plugins.appendingPathComponent("ntfyNSE.appex/ntfy.momd")), ("share", plugins.appendingPathComponent("ntfyShare.appex/ntfy.momd"))] {
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: url), name)
            XCTAssertEqual(model.entityVersionHashesByName, store.container.managedObjectModel.entityVersionHashesByName, name)
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("VersionInfo.plist")), format: nil) as? [String: Any])
            XCTAssertEqual(info["NSManagedObjectModel_CurrentVersionName"] as? String, "Model 10", name)
            let attribute = try XCTUnwrap(model.entitiesByName["Subscription"]?.attributesByName["subscribedAt"], name)
            XCTAssertTrue(attribute.isOptional); XCTAssertEqual(attribute.attributeType, .dateAttributeType)
            XCTAssertNil(attribute.defaultValue, "Migration must not invent a subscription time")
            for version in ["Model"] + (2...9).map({ "Model \($0)" }) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(version + ".mom").path), "\(name) missing \(version)")
            }
            print("SUBSCRIPTION_DATE_BUNDLE target=\(name) current=Model10 optionalDate=true previousVersions=9")
        }
    }

    func testModel9StoreSurvivesAppNSEAndShareFirstUpgradeWithUnknownDates() throws {
        let momd = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        for opener in ["app", "nse", "share"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("model9.sqlite")
            let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: momd.appendingPathComponent("Model 9.mom")))
            XCTAssertNil(oldModel.entitiesByName["Subscription"]?.attributesByName["subscribedAt"])
            oldModel.entities.forEach { $0.managedObjectClassName = "NSManagedObject" }
            let old = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
            let disk = try old.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [NSPersistentHistoryTrackingKey: true])
            let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            writer.persistentStoreCoordinator = old
            let sub = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: writer)
            sub.setValue(base, forKey: "baseUrl"); sub.setValue("upgrade", forKey: "topic")
            sub.setValue("Preserved name", forKey: "customDisplayName"); sub.setValue(true, forKey: "pinned")
            sub.setValue(Date.distantFuture, forKey: "mutedUntil")
            let message = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: writer)
            message.setValue("before-upgrade", forKey: "id"); message.setValue("Preserved message", forKey: "message")
            message.setValue(sub, forKey: "subscription"); message.setValue(Int64(1), forKey: "time")
            message.setValue(false, forKey: "read")
            let pref = NSEntityDescription.insertNewObject(forEntityName: "Preference", into: writer)
            pref.setValue("kept", forKey: "key"); pref.setValue("value", forKey: "value")
            try writer.save(); writer.reset(); try old.remove(disk)

            // Use the actual compiled model in whichever bundle is the first opener.
            let modelURL = opener == "app" ? momd : plugins.appendingPathComponent("\(opener == "nse" ? "ntfyNSE" : "ntfyShare").appex/ntfy.momd")
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL)?.copy() as? NSManagedObjectModel)
            model.entities.forEach { $0.managedObjectClassName = "NSManagedObject" }
            let migrated = NSPersistentStoreCoordinator(managedObjectModel: model)
            let migratedDisk = try migrated.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true,
                          NSPersistentHistoryTrackingKey: true, NSPersistentStoreRemoteChangeNotificationPostOptionKey: true])
            let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            reader.persistentStoreCoordinator = migrated
            let rows = try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: "Subscription"))
            XCTAssertEqual(rows.count, 1)
            let legacy = try XCTUnwrap(rows.first)
            XCTAssertNil(try date(legacy))
            XCTAssertEqual(legacy.value(forKey: "customDisplayName") as? String, "Preserved name")
            XCTAssertEqual(legacy.value(forKey: "pinned") as? Bool, true)
            XCTAssertEqual(legacy.value(forKey: "mutedUntil") as? Date, Date.distantFuture)
            XCTAssertEqual((legacy.value(forKey: "notifications") as? NSSet)?.count, 1)
            reader.reset(); try migrated.remove(migratedDisk)

            // The app can reopen an extension-migrated store and keep legacy state unknown.
            let reopened = Store(inMemory: true, storeURL: url)
            XCTAssertEqual(reopened.container.persistentStoreCoordinator.persistentStores.count, 1)
            let kept = try XCTUnwrap(reopened.getSubscription(baseUrl: base, topic: "upgrade"))
            XCTAssertNil(try date(kept)); XCTAssertEqual(kept.unreadCount(), 1)
            let messages = try reopened.context.fetch(ntfy.Notification.fetchRequest())
            XCTAssertEqual(messages.first?.message, "Preserved message")
            let preferences = try reopened.context.fetch(Preference.fetchRequest())
            XCTAssertTrue(preferences.contains { $0.key == "kept" && $0.value == "value" })
            let before = Date()
            let new = reopened.saveSubscription(baseUrl: base, topic: "after-upgrade")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(date(new)), before)
            reopened.context.reset()
            for disk in reopened.container.persistentStoreCoordinator.persistentStores { try reopened.container.persistentStoreCoordinator.remove(disk) }
            print("SUBSCRIPTION_DATE_MIGRATION source=Model9 first=\(opener) legacyRows=1 messages=1 preferences=1 legacyDate=nil newDate=recorded reopen=passed")
        }
    }
}

extension SubscriptionDateTests {
    private final class Subscriber: FcmTopicSubscriber {
        var hasApnsToken = false
        func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
        func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
    }

    func testInAppLinkQRAndManagedCreationShareTheDateBoundary() throws {
        let suite = "SubscriptionDateTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var manager = SubscriptionManager(store: store,
            reconciler: FcmSubscriptionReconciler(store: store, subscriber: Subscriber(), defaults: defaults),
            polling: PollCoordinator(defaults: defaults))
        manager.fetch = { _, completion in completion([], nil) }
        let before = Date()
        manager.subscribe(baseUrl: base, topic: "manual")
        // Links and QR scans prefill Add, whose Subscribe button calls the same manager.
        let link = try XCTUnwrap(TopicLink(scanned: base + "/link"))
        let qr = try XCTUnwrap(TopicLink(scanned: XCTUnwrap(TopicQRCode.payload(baseUrl: base, topic: "qr"))))
        for input in [link, qr] { manager.subscribe(baseUrl: input.server, topic: input.topic) }
        defaults.set(["topics": [["server": base, "topic": "managed"]]], forKey: ManagedConfiguration.configurationKey)
        let managed = ManagedConfiguration(manager: manager, defaults: defaults)
        managed.refresh()
        for topic in ["manual", "link", "qr", "managed"] {
            let row = try XCTUnwrap(store.getSubscription(baseUrl: base, topic: topic))
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(date(row)), before, topic)
        }
        let original = try XCTUnwrap(store.getSubscription(baseUrl: base, topic: "managed"))
        let created = try date(original)
        managed.refresh()
        XCTAssertEqual(try date(original), created, "Reapplying MDM must not restamp a topic")
        // Management adopting a previously undated personal topic must keep it undated.
        original.setValue(nil, forKey: "subscribedAt"); try store.context.save()
        managed.refresh()
        XCTAssertNil(try date(original))
        let drained = expectation(description: "reconciliation settled")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}

extension SubscriptionDateTests {
    func testDetailsStringsResolveInAllSevenLanguages() throws {
        let labels = ["en": "Topic details", "de": "Themendetails", "es": "Detalles del tópico",
                      "fr": "Détails du sujet", "it": "Dettagli dell’argomento", "nl": "Onderwerpdetails", "pl": "Szczegóły tematu"]
        let unknownDates = ["en": "Unknown", "de": "Unbekannt", "es": "Desconocida", "fr": "Inconnue",
                            "it": "Sconosciuta", "nl": "Onbekend", "pl": "Nieznana"]
        for (language, expected) in labels {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Topic details", value: nil, table: nil), expected)
            XCTAssertEqual(bundle.localizedString(forKey: "Subscription date unknown", value: nil, table: nil), unknownDates[language])
            for key in ["About this topic", "Topic URL", "Subscribed", "The subscription date was not recorded for this topic."] {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
                if language != "en" { XCTAssertNotEqual(value, key, "\(language): \(key)") }
                XCTAssertFalse(value.contains("\u{2014}"))
            }
            if language == "es" {
                XCTAssertEqual(bundle.localizedString(forKey: "Topic URL", value: nil, table: nil), "URL del tópico")
            }
        }
    }
}

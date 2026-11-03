import XCTest
import CoreData
import AppIntents
@testable import ntfy

@available(iOS 16.0, *)
@MainActor
final class ShortcutsReadTests: XCTestCase {
    func testReadActionIsExportedForShortcutsWithStructuredOutput() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try XCTUnwrap(metadata["actions"] as? [String: Any])
        let read = try XCTUnwrap(actions["ReadMessagesIntent"] as? [String: Any], "Read messages must be available to Shortcuts")
        XCTAssertEqual((read["title"] as? [String: Any])?["key"] as? String, "Read messages")
        let parameters = try XCTUnwrap(read["parameters"] as? [[String: Any]])
        XCTAssertEqual(parameters.compactMap { $0["name"] as? String }, ["topic", "limit", "since"])
        XCTAssertEqual(read["openAppWhenRun"] as? Bool, false)
        let entities = try XCTUnwrap(metadata["entities"] as? [String: Any])
        let entity = try XCTUnwrap(entities["StoredMessage"] as? [String: Any])
        let properties = try XCTUnwrap(entity["properties"] as? [[String: Any]])
        XCTAssertEqual(properties.compactMap { $0["identifier"] as? String }, ["message", "title", "priority", "tags", "clickURL", "time"])
        let output = try XCTUnwrap(read["outputType"] as? [String: Any])
        let outputJSON = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        XCTAssertTrue(outputJSON.contains("array"))
        XCTAssertTrue(outputJSON.contains("StoredMessage"))
    }
    private func fixture() -> (Store, Subscription, ReadMessagesIntent) {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore(), topicSecrets: InMemoryTopicSecretStore())
        let sub = store.saveSubscription(baseUrl: "https://example.org/prefix", topic: "automation")
        var intent = ReadMessagesIntent()
        intent.topic = SubscribedTopic(subscription: sub)
        return (store, sub, intent)
    }
    @discardableResult
    private func row(_ id: String, time: Int64, sub: Subscription, store: Store, body: String = "body") throws -> ntfy.Notification {
        let n = ntfy.Notification(context: store.context)
        n.id = id; n.message = body; n.time = time; n.subscription = sub
        try store.context.save()
        return n
    }

    func testNewestFirstDefaultOneAndAllOutputPropertiesWithoutDisplayDecoration() throws {
        let (store, sub, intent) = fixture()
        try row("older", time: 10, sub: sub, store: store)
        let n = try row("newer", time: 20, sub: sub, store: store, body: "{\"event\":\"dishwasher_finished\",\"task\":\"Empty dishwasher\"}")
        n.title = "Dishwasher"; n.priority = 5; n.tags = "white_check_mark,home"; n.click = "https://example.org/task"
        try store.context.save()
        let result = try intent.read(store: store)
        let message = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(message.message, n.message)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(message.message.utf8)) as? [String: String])
        XCTAssertEqual(message.title, "Dishwasher")
        XCTAssertEqual(message.priority, 5)
        XCTAssertEqual(message.tags, ["white_check_mark", "home"])
        XCTAssertEqual(message.clickURL, URL(string: "https://example.org/task"))
        XCTAssertEqual(message.time, Date(timeIntervalSince1970: 20))
    }

    func testLimitSinceExclusiveAndStableTieOrdering() throws {
        let (store, sub, original) = fixture(); var intent = original
        for (id, time): (String, Int64) in [("a",10),("b",20),("c",20),("d",30)] {
            try row(id, time: time, sub: sub, store: store, body: id)
        }
        intent.limit = 2
        XCTAssertEqual(try intent.read(store: store).map(\.message), ["d", "c"])
        intent.since = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(try intent.read(store: store).map(\.message), ["d"])
        intent.since = Date(timeIntervalSince1970: 19.5)
        intent.limit = 100
        XCTAssertEqual(try intent.read(store: store).map(\.message), ["d", "c", "b"])
        intent.since = Date(timeIntervalSince1970: 40)
        XCTAssertTrue(try intent.read(store: store).isEmpty)
    }

    func testSinceAt2026EpochThatRoundsUpPreservesExclusiveBoundary() throws {
        try assertSinceBoundary(at: 1_793_663_826)
    }

    func testSinceAt2026EpochThatRoundsDownPreservesExclusiveBoundary() throws {
        try assertSinceBoundary(at: 1_793_663_873)
    }

    private func assertSinceBoundary(at cutoff: Int64) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Exercise SQLite's integer time column through the real fresh-context read query.
        let store = Store(inMemory: true, storeURL: directory.appendingPathComponent("since.sqlite"),
                          credentialStore: InMemoryCredentialStore(), topicSecrets: InMemoryTopicSecretStore())
        defer {
            for persistentStore in store.container.persistentStoreCoordinator.persistentStores {
                try? store.container.persistentStoreCoordinator.remove(persistentStore)
            }
        }
        let sub = store.saveSubscription(baseUrl: "https://example.org", topic: "since-boundary")
        for (id, offset): (String, Int64) in [("before", -1), ("exact", 0), ("after1", 1), ("after2", 2)] {
            try row(id, time: cutoff + offset, sub: sub, store: store, body: id)
        }
        var intent = ReadMessagesIntent()
        intent.topic = SubscribedTopic(subscription: sub)
        intent.limit = 100
        for (offset, expected): (Double, [String]) in [
            (-0.5, ["after2", "after1", "exact"]),
            (0, ["after2", "after1"]),
            (0.5, ["after2", "after1"]),
            (1.5, ["after2"]),
            (2, []),
            (3, [])
        ] {
            intent.since = Date(timeIntervalSince1970: Double(cutoff) + offset)
            XCTAssertEqual(try intent.read(store: store).map(\.message), expected,
                           "Exclusive cutoff \(cutoff) + \(offset)")
        }
    }

    func testSameNameOnOtherServerIsExcludedAndReadingDoesNotMarkRead() throws {
        let (store, sub, intent) = fixture()
        let other = store.saveSubscription(baseUrl: "https://another.example.org", topic: "automation")
        let n = try row("selected", time: 10, sub: sub, store: store); n.read = false
        try row("other", time: 20, sub: other, store: store)
        try store.context.save()
        XCTAssertEqual(try intent.read(store: store).map(\.id), [n.objectID.uriRepresentation().absoluteString])
        store.context.refresh(n, mergeChanges: false)
        XCTAssertFalse(n.read)
    }

    func testEmptyMissingAndDeletedTopicsAndInvalidLimits() throws {
        let (store, sub, original) = fixture(); var intent = original
        XCTAssertTrue(try intent.read(store: store).isEmpty)
        for invalid in [0, -1, 101, Int.max] {
            intent.limit = invalid
            XCTAssertThrowsError(try intent.read(store: store))
        }
        intent.limit = 1
        store.context.delete(sub); try store.context.save()
        XCTAssertThrowsError(try intent.read(store: store))
    }

    func testLockedNeverReturnsCiphertextAndDecryptedJSONStaysReadable() throws {
        let (store, sub, original) = fixture(); var intent = original
        let locked = try row("locked", time: 20, sub: sub, store: store, body: "ciphertext must never escape")
        locked.encryption = NotificationEncryption.locked.rawValue
        locked.ciphertext = "private envelope"
        let clear = try row("clear", time: 10, sub: sub, store: store, body: "{\"task\":\"Empty dishwasher\"}")
        clear.encryption = NotificationEncryption.decrypted.rawValue
        clear.ciphertext = "another private envelope"
        try store.context.save(); intent.limit = 10
        let result = try intent.read(store: store)
        XCTAssertEqual(result.map(\.message), [String(localized: "Encrypted message"), clear.message])
        XCTAssertEqual(result.last?.tags, [])
        XCTAssertNil(result.last?.clickURL)
        XCTAssertEqual(result.last?.title, "")
        XCTAssertEqual(result.last?.priority, 3)
    }

    func testFreshContextSeesSeparateWriterAndEntityQueryResolvesInRequestedOrder() throws {
        let (store, sub, intent) = fixture()
        XCTAssertTrue(try intent.read(store: store).isEmpty)
        let writer = SubscribedTopicQuery.readContext(store: store)
        let otherSub = try XCTUnwrap(try writer.existingObject(with: sub.objectID) as? Subscription)
        let n = ntfy.Notification(context: writer)
        n.id = "external"; n.message = "from another context"; n.time = 100; n.subscription = otherSub
        try writer.save()
        let result = try intent.read(store: store)
        XCTAssertEqual(result.first?.message, "from another context")
        let id = try XCTUnwrap(result.first?.id)
        XCTAssertEqual(try StoredMessageQuery.resolve(["invalid", "x-coredata://bad", "x-coredata://bad/Notification/p1", "x-coredata://bad/Notification/invalid", "file:///Notification/p1", id], store: store).map(\.id), [id])
        writer.delete(n); try writer.save()
        XCTAssertTrue(try intent.read(store: store).isEmpty)
        XCTAssertTrue(try StoredMessageQuery.resolve([id], store: store).isEmpty)
    }

    func testPerformReturnsActualStructuredIntentResultAndRequiresUnlock() async throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://read-perform.example.org", topic: "read-perform")
        defer { store.context.delete(sub); try? store.context.save() }
        try row("read-perform", time: 1, sub: sub, store: store, body: "shortcut output")
        var intent = ReadMessagesIntent(); intent.topic = SubscribedTopic(subscription: sub)
        let result = try await intent.perform()
        XCTAssertEqual(result.value?.first?.message, "shortcut output")
        XCTAssertFalse(ReadMessagesIntent.openAppWhenRun)
        XCTAssertEqual(ReadMessagesIntent.authenticationPolicy, .requiresAuthentication)
    }

    func testActualEncryptedIngressReturnsDecryptedFieldsOrLockedPlaceholder() throws {
        let (store, sub, original) = fixture(); var intent = original
        let key = Data(repeating: 9, count: 32)
        sub.encrypted = true
        XCTAssertTrue(store.topicSecrets.setTopicSecret(password: "test", key: key, topicUrl: sub.urlString()))
        try store.context.save()
        let payload = EncryptedPayload(message: "{\"task\":\"Empty dishwasher\"}", title: "Maintenance", tags: ["home"], priority: 4, click: "https://example.org/task")
        let jwe = try TopicEncryption.encrypt(payload, key: key)
        XCTAssertTrue(store.save(notificationFromMessage: Message(id: "decrypted-ingress", time: 10, event: "message", topic: sub.topic!, message: jwe), baseUrl: sub.baseUrl!, topic: sub.topic!))
        let decrypted = try XCTUnwrap(try intent.read(store: store).first)
        XCTAssertEqual(decrypted.message, payload.message)
        XCTAssertEqual(decrypted.title, payload.title)
        XCTAssertEqual(decrypted.tags, payload.tags)
        XCTAssertEqual(decrypted.priority, payload.priority)
        XCTAssertEqual(decrypted.clickURL?.absoluteString, payload.click)
        store.topicSecrets = InMemoryTopicSecretStore()
        let lockedJWE = try TopicEncryption.encrypt(payload, key: key)
        XCTAssertTrue(store.save(notificationFromMessage: Message(id: "locked-ingress", time: 20, event: "message", topic: sub.topic!, message: lockedJWE), baseUrl: sub.baseUrl!, topic: sub.topic!))
        intent.limit = 2
        let messages = try intent.read(store: store)
        XCTAssertEqual(messages.first?.message, String(localized: "Encrypted message"))
        XCTAssertFalse(messages.contains { $0.message == jwe || $0.message == lockedJWE })
    }

}

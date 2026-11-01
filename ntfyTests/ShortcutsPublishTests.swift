import XCTest
import AppIntents
import CoreData
import Network
@testable import ntfy

@available(iOS 16.0, *)
@MainActor
final class ShortcutsPublishTests: XCTestCase {
    private func fixture(status: Int = 200) async throws -> (ShortcutHTTPServer, Store, Subscription, ApiService) {
        let server = try ShortcutHTTPServer(status: status)
        await server.start()
        let credentials = InMemoryCredentialStore()
        let store = Store(inMemory: true, credentialStore: credentials, topicSecrets: InMemoryTopicSecretStore())
        let topic = store.saveSubscription(baseUrl: "http://127.0.0.1:\(server.port)/prefix/", topic: "audit")
        return (server, store, topic, ApiService(credentialStore: credentials))
    }
    private func intent(_ topic: Subscription) -> SendMessageIntent {
        var intent = SendMessageIntent()
        intent.topic = SubscribedTopic(subscription: topic)
        intent.message = "Message body\nSecond line"
        intent.messageTitle = "Title"
        intent.priority = 5
        intent.tags = "warning, cat , ,memo"
        intent.clickURL = "https://example.org/action"
        return intent
    }
    private func failure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { try await action(); XCTFail("Failure was reported as success", file: file, line: line); return "" }
        catch { return error.localizedDescription }
    }

    func testActualHTTPPathHeadersBodyAndStoredBasicSignIn() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        let credentials = store.credentialStore
        let user = User(context: store.context); user.password = ""
        user.baseUrl = topic.baseUrl; user.username = "test-user"
        credentials.setCredential(.basic(username: "test-user", password: "test-password"), baseUrl: topic.baseUrl!)
        try store.context.save()
        try await intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil))
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/prefix/audit")
        XCTAssertEqual(request.headers["authorization"], "Basic dGVzdC11c2VyOnRlc3QtcGFzc3dvcmQ=")
        XCTAssertEqual(request.headers["title"], "Title")
        XCTAssertEqual(request.headers["priority"], "5")
        XCTAssertEqual(request.headers["tags"], "warning,cat,memo")
        XCTAssertEqual(request.headers["click"], "https://example.org/action")
        XCTAssertEqual(request.body, Data("Message body\nSecond line".utf8))
    }

    func testStoredBearerAndCustomHeadersUseComposeTransport() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        let user = User(context: store.context); user.password = ""; user.baseUrl = topic.baseUrl; user.username = ""
        store.credentialStore.setCredential(.accessToken("tk_shortcuts_test"), baseUrl: topic.baseUrl!)
        store.credentialStore.setHTTPHeaders(["X-Proxy-Key": "test-proxy"], baseUrl: topic.baseUrl!)
        try store.context.save()
        try await intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil))
        XCTAssertEqual(server.requests.first?.headers["authorization"], "Bearer tk_shortcuts_test")
        XCTAssertEqual(server.requests.first?.headers["x-proxy-key"], "test-proxy")
    }

    func testEncryptedPayloadContainsAllPrivateFieldsAndNoPlaintextHeaders() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        topic.encrypted = true
        let key = Data(repeating: 7, count: 32)
        XCTAssertTrue(store.topicSecrets.setTopicSecret(password: "test", key: key, topicUrl: topic.urlString()))
        try store.context.save()
        try await intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil))
        let request = try XCTUnwrap(server.requests.first)
        let payload = try TopicEncryption.decryptPayload(String(decoding: request.body, as: UTF8.self), key: key)
        XCTAssertEqual(payload.message, "Message body\nSecond line")
        XCTAssertEqual(payload.title, "Title")
        XCTAssertEqual(payload.tags, ["warning", "cat", "memo"])
        XCTAssertEqual(payload.priority, 5)
        XCTAssertEqual(payload.click, "https://example.org/action")
        for header in ["title", "priority", "tags", "click"] { XCTAssertNil(request.headers[header]) }
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("Message body"))
    }

    func testMissingAndLockedEncryptionKeysNeverSendPlaintext() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        topic.encrypted = true; try store.context.save()
        for status: OSStatus? in [nil, errSecInteractionNotAllowed] {
            (store.topicSecrets as! InMemoryTopicSecretStore).failReads = status
            let error = await failure { try await self.intent(topic).send(store: store, api: api) }
            XCTAssertEqual(error, String(localized: "The encryption password is unavailable. Unlock your phone or set the topic password again. Nothing was sent."))
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testUnreadableSavedSignInAndProxyHeadersNeverSendAnonymously() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        let user = User(context: store.context); user.password = ""; user.baseUrl = topic.baseUrl; user.username = "saved"
        try store.context.save()
        let credentials = store.credentialStore as! InMemoryCredentialStore
        credentials.setPasswordReadsFail(true)
        let expected = String(localized: "The server sign-in is unavailable. Unlock your phone or sign in again in Settings. Nothing was sent.")
        let actual = await failure { try await self.intent(topic).send(store: store, api: api) }
        XCTAssertEqual(actual, expected)
        store.context.delete(user); try store.context.save()
        credentials.setHeaderReadsFail(true)
        let headerError = await failure { try await self.intent(topic).send(store: store, api: api) }
        XCTAssertEqual(headerError, expected)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testDeletedSubscriptionDoesNotPublishToCachedEntity() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        let action = intent(topic)
        store.context.delete(topic); try store.context.save()
        let error = await failure { try await action.send(store: store, api: api) }
        XCTAssertEqual(error, String(localized: "This topic is no longer subscribed. Choose another topic or subscribe again in NTFY me. Nothing was sent."))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testHTTP401And403ExplainSignInRefusal() async throws {
        for status in [401, 403] {
            let (server, store, topic, api) = try await fixture(status: status); defer { server.stop() }
            let error = await failure { try await self.intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil)) }
            XCTAssertEqual(server.requests.count, 1)
            XCTAssertEqual(error, ApiService.PublishError.http(status).userMessage)
        }
    }

    func testRateLimitAndSubsequentCooldownAreErrorsWithRetryInstructions() async throws {
        let (server, store, topic, api) = try await fixture(status: 429); defer { server.stop() }
        let cooldown = ServerCooldown(defaults: nil)
        for _ in 0..<2 {
            let error = await failure { try await self.intent(topic).send(store: store, api: api, cooldown: cooldown) }
            XCTAssertTrue(error.contains("Try again in"), error)
            XCTAssertFalse(error.contains("draft"), "Shortcuts has no saved compose draft")
        }
        XCTAssertEqual(server.requests.count, 1, "Cooldown must stop a second HTTP request")
    }

    func testConditionalRateLimitExplainsRequiredChange() async throws {
        let (server, store, topic, api) = try await fixture(status: 429); defer { server.stop() }
        server.condition = "request-change"
        let error = await failure { try await self.intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil)) }
        XCTAssertEqual(error, ApiService.PublishError.publishNeedsChange.userMessage)
    }

    func testNetworkFailureWarnsToCheckDeliveryBeforeRetry() async throws {
        let (server, store, topic, api) = try await fixture()
        server.stop()
        let error = await failure { try await self.intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil)) }
        XCTAssertTrue(error.contains("Could not reach the server"), error)
        XCTAssertTrue(error.contains("look for the message in the topic before sending again"), error)
    }

    func testOtherHTTPRefusalsRemainErrors() async throws {
        for status in [400, 413, 500] {
            let (server, store, topic, api) = try await fixture(status: status); defer { server.stop() }
            let error = await failure { try await self.intent(topic).send(store: store, api: api, cooldown: ServerCooldown(defaults: nil)) }
            XCTAssertEqual(error, ApiService.PublishError.http(status).userMessage)
        }
    }

    func testPerformRejectsWhitespaceAndHelperRejectsOutOfRangePriority() async throws {
        let (server, store, topic, api) = try await fixture(); defer { server.stop() }
        var action = intent(topic); action.message = " \n "
        let error = await failure { _ = try await action.perform() }
        XCTAssertEqual(error, String(localized: "Enter a message to send. Nothing was sent."))
        action.message = "body"; action.priority = 6
        let priorityError = await failure { try await action.send(store: store, api: api) }
        XCTAssertEqual(priorityError, String(localized: "Choose a priority from 1 to 5. Nothing was sent."))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testTopicQueryUsesSavedSubscriptionsNamesAndNondefaultServers() throws {
        let store = Store(inMemory: true)
        let main = store.saveSubscription(baseUrl: Config.appBaseUrl, topic: "plain")
        let named = store.saveSubscription(baseUrl: "https://other.example.org/ntfy/", topic: "raw")
        named.customDisplayName = "My alerts"; try store.context.save()
        let topics = try SubscribedTopicQuery.topics(store: store)
        XCTAssertEqual(topics.count, 2)
        let defaultTopic = try XCTUnwrap(topics.first { $0.id == main.objectID.uriRepresentation().absoluteString })
        XCTAssertEqual(defaultTopic.name, "plain"); XCTAssertNil(defaultTopic.server)
        let selected = try XCTUnwrap(topics.first { $0.name == "My alerts" })
        XCTAssertEqual(selected.server, "other.example.org/ntfy")
        XCTAssertEqual(try SubscribedTopicQuery.topics(identifiers: [selected.id, "missing", defaultTopic.id], store: store).map(\.id), [selected.id, defaultTopic.id])
        named.customDisplayName = "Renamed"; try store.context.save()
        XCTAssertEqual(try SubscribedTopicQuery.topics(identifiers: [selected.id], store: store).first?.name, "Renamed")
        store.context.delete(named); try store.context.save()
        XCTAssertTrue(try SubscribedTopicQuery.topics(identifiers: [selected.id], store: store).isEmpty)
        XCTAssertFalse(store.context.hasChanges, "Query must not edit Core Data")
    }

    func testActualPerformPublishesWithoutOpeningAppAndReturnsSuccess() async throws {
        let server = try ShortcutHTTPServer(status: 200); await server.start(); defer { server.stop() }
        let store = Store.shared
        let previousCredentials = store.credentialStore
        store.credentialStore = InMemoryCredentialStore()
        let sub = store.saveSubscription(baseUrl: "http://127.0.0.1:\(server.port)", topic: "perform")
        defer {
            store.credentialStore = previousCredentials
            store.context.delete(sub); try? store.context.save()
        }
        _ = try await intent(sub).perform()
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.path, "/perform")
        XCTAssertEqual(server.requests.first?.body, Data("Message body\nSecond line".utf8))
    }

    func testPublicQuerySuggestionsSearchAndIdentifierResolution() async throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://shortcuts-query.example.org", topic: UUID().uuidString)
        sub.customDisplayName = "Shortcut query " + UUID().uuidString
        try store.context.save()
        defer { store.context.delete(sub); try? store.context.save() }
        let query = SubscribedTopicQuery()
        let entity = SubscribedTopic(subscription: sub)
        let suggested = try await query.suggestedEntities()
        XCTAssertTrue(suggested.contains { $0.id == entity.id && $0.name == sub.customDisplayName })
        let matched = try await query.entities(matching: sub.customDisplayName!.uppercased())
        XCTAssertEqual(matched.map(\.id), [entity.id])
        let serverMatch = try await query.entities(matching: "shortcuts-query.example.org")
        XCTAssertTrue(serverMatch.contains { $0.id == entity.id })
        let resolved = try await query.entities(for: [entity.id, "missing"])
        XCTAssertEqual(resolved.map(\.id), [entity.id])
    }

    func testEmptyTopicQueryAndBackgroundPolicy() throws {
        XCTAssertTrue(try SubscribedTopicQuery.topics(store: Store(inMemory: true)).isEmpty)
        XCTAssertFalse(SendMessageIntent.openAppWhenRun)
        XCTAssertEqual(SendMessageIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(MessageAppShortcuts.appShortcuts.count, 1)
    }
}

/// Adapted from the existing NSEAuthLoopbackServer fixture, with full HTTP body capture.
private final class ShortcutHTTPServer {
    struct Request { let path: String; let headers: [String: String]; let body: Data }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfy.tests.shortcuts-http")
    private var connections: [NWConnection] = []
    private var stopped = false
    private var captured: [Request] = []
    private let status: Int
    var condition: String?
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [Request] { queue.sync { captured } }
    init(status: Int) throws {
        self.status = status
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in if case .ready = state { continuation.resume() } }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }
    private func receive(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard !self.stopped else { return }
            var bytes = buffered; bytes.append(data ?? Data())
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let body = Data(bytes[split.upperBound...])
                if body.count >= length {
                    let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                    self.captured.append(Request(path: path, headers: headers, body: body))
                    let condition = self.condition.map { "Retry-After-Condition: \($0)\r\n" } ?? ""
                    let response = Data("HTTP/1.1 \(self.status) Test\r\nContent-Length: 2\r\nRetry-After: 60\r\n\(condition)Connection: close\r\n\r\n{}".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            guard !complete, error == nil else { connection.cancel(); return }
            self.receive(on: connection, buffered: bytes)
        }
    }
    func stop() {
        queue.sync { stopped = true; listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

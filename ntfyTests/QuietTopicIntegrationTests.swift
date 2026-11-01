import XCTest
import UserNotifications
import CryptoKit
import Network
@testable import ntfy

/// These tests compile against unmodified main. Seed the proposed App Group wire format and a
/// real pending request, then exercise existing entry points without calling a new scheduler API.
final class QuietTopicIntegrationTests: XCTestCase {
    private let center = UNUserNotificationCenter.current()
    private var subscriptions: [Subscription] = []
    private var keys: [String] = []
    private let defaults = UserDefaults(suiteName: Config.appGroupId)!

    override func setUpWithError() throws {
        let done = expectation(description: "notification authorization")
        var authorized = false
        center.getNotificationSettings { settings in
            authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard authorized else { throw XCTSkip("Real notification-center integration requires notification permission") }
    }

    private func key(_ sub: Subscription) -> String {
        let identity = sub.objectID.uriRepresentation().absoluteString
        return "quietTopic.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func watched(base: String = "https://quiet.example", topic: String = UUID().uuidString) throws -> Subscription {
        let sub = Store.shared.saveSubscription(baseUrl: base, topic: topic)
        subscriptions.append(sub)
        let id = key(sub); keys.append(id)
        defaults.set(["interval": 900.0, "received": Date().timeIntervalSince1970 - 120,
                      "baseUrl": base, "topic": topic, "title": topic], forKey: id)
        defaults.synchronize()
        let content = UNMutableNotificationContent(); content.title = "sentinel"
        let done = expectation(description: "seed real pending notification")
        center.add(UNNotificationRequest(identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 100, repeats: false))) { error in
            XCTAssertNil(error); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(pending(sub), "Fixture must retain a pending request before exercising production")
        return sub
    }

    private func pending(_ sub: Subscription) -> UNNotificationRequest? {
        let done = expectation(description: "read pending local requests")
        var found: UNNotificationRequest?
        center.getPendingNotificationRequests { requests in
            found = requests.first { $0.identifier == self.key(sub) }; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return found
    }

    private func settle() {
        let done = expectation(description: "allow scheduler callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    override func tearDown() {
        for sub in subscriptions where !sub.isDeleted { _ = Store.shared.delete(subscription: sub) }
        settle()
        center.removePendingNotificationRequests(withIdentifiers: keys)
        center.removeDeliveredNotifications(withIdentifiers: keys)
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.synchronize()
        super.tearDown()
    }

    private func message(_ sub: Subscription, event: String = "message") -> Message {
        Message(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970), event: event,
                topic: sub.topic!, message: "heartbeat")
    }

    private func assertRestarted(_ sub: Subscription, other: Subscription, file: StaticString = #filePath, line: UInt = #line) throws {
        settle()
        let request = try XCTUnwrap(pending(sub), file: file, line: line)
        XCTAssertEqual(request.content.title, sub.topic!, file: file, line: line)
        XCTAssertEqual(request.content.body, "No message received for 15 minutes.", file: file, line: line)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger, file: file, line: line)
        XCTAssertGreaterThan(trigger.timeInterval, 895, file: file, line: line)
        XCTAssertFalse(trigger.repeats, file: file, line: line)
        XCTAssertEqual(pending(other)?.content.title, "sentinel", file: file, line: line)
    }

    func testForegroundDelegateRestartsOnlyIncomingTopic() throws {
        let sub = try watched(), other = try watched()
        let payload = UNMutableNotificationContent(); payload.userInfo = message(sub).toUserInfo()
        payload.userInfo["base_url"] = sub.baseUrl!; payload.sound = .default
        // Obtain an actual UNNotification from OS delivery, then call the real foreground delegate.
        let delegate = QuietForegroundCapture()
        let previous = center.delegate; center.delegate = delegate
        defer { center.delegate = previous }
        let delivered = expectation(description: "foreground OS delivery")
        delegate.capture = { notification in
            AppDelegate().userNotificationCenter(self.center, willPresent: notification) { _ in delivered.fulfill() }
        }
        center.add(UNNotificationRequest(identifier: "quiet-fg-" + UUID().uuidString, content: payload, trigger: nil))
        wait(for: [delivered], timeout: 5)
        try assertRestarted(sub, other: other)
    }

    func testAppPollAndRefreshPathsRestartOnlyTheirTopic() throws {
        for poll in [false, true] {
            let sub = try watched(), other = try watched()
            if poll {
                let request = try XCTUnwrap(Store.shared.pollRequest(for: sub))
                XCTAssertNotNil(Store.shared.save(notificationsFromMessages: [message(sub)], polledWith: request))
            } else {
                Store.shared.save(notificationFromMessage: message(sub), withSubscription: sub)
            }
            try assertRestarted(sub, other: other)
        }
    }

    func testNSEDirectEntryRestartsOnlyIncomingTopicEvenWhenMuted() throws {
        let sub = try watched(), other = try watched()
        try Store.shared.setTopicMute(until: .distantFuture, subscription: sub)
        let content = UNMutableNotificationContent(); content.userInfo = message(sub).toUserInfo()
        content.userInfo["base_url"] = sub.baseUrl!
        let done = expectation(description: "NSE content handoff")
        let service = NotificationService()
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done.fulfill() }
        wait(for: [done], timeout: 6)
        try assertRestarted(sub, other: other)
        withExtendedLifetime(service) {}
    }

    func testNSELoopbackPollEntryRestartsOnlyFetchedTopic() throws {
        let server = try QuietLoopbackServer()
        let ready = expectation(description: "HTTP ready"); server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5); defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let sub = try watched(base: base, topic: "monitor"), other = try watched(base: base, topic: "other")
        let content = UNMutableNotificationContent()
        content.userInfo = ["id": "wake", "time": "1800000000", "event": "poll_request", "poll_id": "quietpoll123", "topic": sub.topic!, "base_url": base]
        let done = expectation(description: "NSE polled content handoff")
        let service = NotificationService()
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { result in
            XCTAssertEqual(result.body, "alive"); done.fulfill()
        }
        wait(for: [done], timeout: 8)
        XCTAssertTrue(server.sawPoll)
        try assertRestarted(sub, other: other)
        withExtendedLifetime(service) {}
    }

    func testEncryptedTopicNSEMessageRestartsWithoutExposingPayload() throws {
        let sub = try watched(), other = try watched()
        sub.encrypted = true
        try Store.shared.context.save()
        let cipher = try TopicEncryption.encrypt(Data("private heartbeat".utf8), key: Data(repeating: 7, count: 32))
        var msg = message(sub); msg.message = cipher
        let content = UNMutableNotificationContent(); content.userInfo = msg.toUserInfo(); content.userInfo["base_url"] = sub.baseUrl!
        let done = expectation(description: "encrypted NSE handoff")
        let service = NotificationService()
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { result in
            XCTAssertEqual(result.body, "Encrypted message"); done.fulfill()
        }
        wait(for: [done], timeout: 6)
        try assertRestarted(sub, other: other)
        XCTAssertFalse(try XCTUnwrap(pending(sub)).content.body.contains("private heartbeat"))
        withExtendedLifetime(service) {}
    }

    func testSignedInNSELoopbackPollUsesCredentialAndRestartsOnlyItsTopic() throws {
        let server = try QuietLoopbackServer(requireAuthorization: true)
        let ready = expectation(description: "authenticated HTTP ready"); server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5); defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let sub = try watched(base: base, topic: "monitor"), other = try watched(base: base, topic: "other")
        let store = Store.shared, original = Store.shared.credentialStore
        store.credentialStore = QuietTestCredentials()
        XCTAssertTrue(store.saveUser(baseUrl: base, credential: .accessToken("quiet-fixture-token")))
        defer {
            if let user = store.getUser(baseUrl: base) { XCTAssertTrue(store.delete(user: user)) }
            store.credentialStore = original
        }
        let content = UNMutableNotificationContent()
        content.userInfo = ["id": "wake", "time": "1800000000", "event": "poll_request", "poll_id": "quietpoll123", "topic": "monitor", "base_url": base]
        let done = expectation(description: "authenticated NSE handoff")
        let service = NotificationService()
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { result in
            XCTAssertEqual(result.body, "alive"); done.fulfill()
        }
        wait(for: [done], timeout: 8)
        XCTAssertTrue(server.sawPoll)
        try assertRestarted(sub, other: other)
        withExtendedLifetime(service) {}
    }

    func testControlsEmptyPollAndDuplicateDoNotRestartWindow() throws {
        let sub = try watched()
        let request = try XCTUnwrap(Store.shared.pollRequest(for: sub))
        for event in ["message_delete", "message_clear", "open", "keepalive", "poll_request"] {
            _ = Store.shared.ingest(pushedMessage: message(sub, event: event), baseUrl: sub.baseUrl!, topic: sub.topic!)
        }
        _ = Store.shared.save(notificationsFromMessages: [], polledWith: request)
        settle()
        XCTAssertEqual(pending(sub)?.content.title, "sentinel")
        let msg = message(sub)
        Store.shared.save(notificationFromMessage: msg, withSubscription: sub)
        settle()
        let first = (pending(sub)?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        Store.shared.save(notificationFromMessage: msg, withSubscription: sub)
        settle()
        let second = (pending(sub)?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        XCTAssertEqual(try XCTUnwrap(second), try XCTUnwrap(first), accuracy: 0.15)
    }

    func testUnsubscribeRemovesPendingAndSharedChoice() throws {
        let sub = try watched(), other = try watched()
        let id = key(sub)
        XCTAssertTrue(Store.shared.delete(subscription: sub))
        settle()
        let done = expectation(description: "pending after unsubscribe")
        center.getPendingNotificationRequests { requests in
            XCTAssertFalse(requests.contains { $0.identifier == id }); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(defaults.dictionary(forKey: id))
        XCTAssertEqual(pending(other)?.content.title, "sentinel")
    }
}

private final class QuietForegroundCapture: NSObject, UNUserNotificationCenterDelegate {
    var capture: ((UNNotification) -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        capture?(notification); completionHandler([])
    }
}

private final class QuietLoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "quiet.tests.http")
    private var stopped = false
    private var connections: [NWConnection] = []
    private var sawRequest = false
    private let requireAuthorization: Bool
    var sawPoll: Bool { queue.sync { sawRequest } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    init(requireAuthorization: Bool = false) throws {
        self.requireAuthorization = requireAuthorization
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { connection in
            guard !self.stopped else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard !self.stopped else { return }
            var bytes = buffered; bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n".utf8)), bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if !complete, error == nil, data?.isEmpty == false { self.receive(connection, buffered: bytes) }
                else { connection.cancel() }
                return
            }
            let line = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            let headers = String(decoding: bytes, as: UTF8.self)
            let authorized = !self.requireAuthorization || headers.lowercased().contains("authorization: bearer quiet-fixture-token")
            self.sawRequest = line.contains("poll=1&id=quietpoll123") && authorized
            XCTAssertTrue(authorized, "NSE must use the stored bearer credential")
            print("QUIET_NSE_HTTP \(line) response=200")
            let body = "{\"id\":\"quietpoll123\",\"time\":1800000000,\"event\":\"message\",\"topic\":\"monitor\",\"message\":\"alive\"}\n"
            let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { queue.sync { stopped = true; listener.cancel(); connections.forEach { $0.cancel() } } }
}

private final class QuietTestCredentials: CredentialStoring {
    private var credential: ServerCredential?
    func readCredential(baseUrl: String, username: String) -> TopicSecretRead<ServerCredential> { credential.map { .found($0) } ?? .notFound }
    func setCredential(_ credential: ServerCredential, baseUrl: String) -> Bool { self.credential = credential; return true }
    func setPassword(_ password: String?, baseUrl: String) -> Bool { true }
    func password(baseUrl: String) -> String? { nil }
    func readPassword(baseUrl: String) -> TopicSecretRead<String> { .notFound }
    func deletePassword(baseUrl: String) -> Bool { credential = nil; return true }
    func setHTTPHeaders(_ headers: [String: String], baseUrl: String) -> Bool { true }
    func readHTTPHeaders(baseUrl: String) -> HTTPHeadersReadResult { .success([:]) }
    func deleteHTTPHeaders(baseUrl: String) -> Bool { true }
}

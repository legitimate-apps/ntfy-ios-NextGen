import XCTest
import Network
import UserNotifications
import CoreData
@testable import ntfy

final class PollFallbackSoundTests: XCTestCase {
    private var server: PollFallbackSoundHTTPServer!
    private var base: String { "http://127.0.0.1:\(server.port)" }
    private var quietBefore: QuietHours!

    override func setUpWithError() throws {
        quietBefore = QuietHours.load()
        QuietHours().save()
        server = try PollFallbackSoundHTTPServer()
        let ready = expectation(description: "sound fixture ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
    }

    override func tearDown() {
        server.stop()
        quietBefore.save()
        super.tearDown()
    }

    private func check(topic: String, priority: Int? = 3, subscribed: Bool = true,
                       expire: Bool = false, muted: Bool = false, duplicate: Bool = false,
                       custom: Bool = false, quiet: Bool = false, direct: Bool = false,
                       rawBody: String? = nil, encoding: String? = nil, expectedBody: String? = nil) throws {
        let store = Store.shared
        let sub = subscribed ? store.saveSubscription(baseUrl: base, topic: topic) : nil
        defer { if let sub { _ = store.delete(subscription: sub) } }
        if muted, let sub { try store.setTopicMute(until: .distantFuture, subscription: sub) }
        if duplicate {
            let message = Message(id: "authpoll1234", time: 1_700_000_000, event: "message", topic: topic, message: "Already shown")
            store.save(notificationsFromMessages: [message], withSubscription: sub!)
            store.recordPresentation(message: message, baseUrl: base)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PollFallbackSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let library = TopicSoundLibrary(defaults: defaults, container: root)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        if custom, let sub {
            try TopicSoundImporter.installBuiltins(library: library)
            library.setChoice(TopicSound.builtins[0].id, for: sub.objectID.uriRepresentation().absoluteString)
        }
        if quiet { var hours = QuietHours(); hours.enabled = true; hours.start = 0; hours.end = 0; hours.save() }
        let content = UNMutableNotificationContent()
        content.title = "Raw poll probe"
        content.body = rawBody ?? "New message"
        // Exact server presentation shape: mutable alert, no aps.sound or interruption-level.
        content.userInfo = ["id": "authpoll1234", "time": "1700000000", "event": direct ? "message" : "poll_request",
                            "topic": topic, "poll_id": "authpoll1234", "base_url": base, "message": rawBody ?? "Direct probe"]
        if let encoding { content.userInfo["encoding"] = encoding }
        if let priority { content.userInfo["priority"] = String(priority) }
        XCTAssertNil(content.sound)
        let service = NotificationService()
        service.soundLibrary = library
        let delivered = expectation(description: "final NSE sound")
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { output in
            if let expectedBody { XCTAssertEqual(output.body, expectedBody) }
            let silent = muted || duplicate || quiet
            let expected: UNNotificationInterruptionLevel = silent || (priority ?? 3) <= 2 ? .passive : (priority ?? 3) >= 4 ? .timeSensitive : .active
            XCTAssertEqual(output.interruptionLevel, expected)
            if silent { XCTAssertNil(output.sound) }
            else if custom, let sound = output.sound {
                let data = try! NSKeyedArchiver.archivedData(withRootObject: sound, requiringSecureCoding: true)
                let plist = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
                XCTAssertTrue((plist["$objects"] as! [Any]).contains { ($0 as? String) == TopicSound.builtins[0].id })
            } else { XCTAssertEqual(output.sound, .default) }
            print("POLL_SOUND topic=\(topic) priority=\(priority.map(String.init) ?? "nil") direct=\(direct) expiry=\(expire) quiet=\(silent) sound=\(String(describing: output.sound)) level=\(output.interruptionLevel.rawValue) body=\(output.body)")
            delivered.fulfill()
        }
        if expire { service.serviceExtensionTimeWillExpire() }
        wait(for: [delivered], timeout: 5)
        withExtendedLifetime(service) {}
    }

    func testRefusedAndFailedPollsHaveDefaultSound() throws {
        for topic in ["status401", "status403", "status429", "status500"] { try check(topic: topic) }
    }
    func testExpiryAndUnknownTopicHaveDefaultSound() throws {
        try check(topic: "pending", expire: true)
        try check(topic: "unknown", subscribed: false)
        try check(topic: "unknown-encoded", subscribed: false,
                  rawBody: Data("Decoded fallback".utf8).base64EncodedString(), encoding: "base64", expectedBody: "Decoded fallback")
        let encrypted = try TopicEncryption.encrypt(Data("Secret fallback".utf8), key: Data(repeating: 7, count: 32))
        try check(topic: "unknown-encrypted", subscribed: false,
                  rawBody: encrypted, expectedBody: TopicEncryption.lockedPlaceholder)
    }
    func testFallbackHonorsPriorityIncludingMissingRelayPriority() throws {
        for priority in [nil, 1, 2, 4, 5] { try check(topic: "status500", priority: priority) }
    }
    func testFallbackPreservesTopicSound() throws { try check(topic: "status500", custom: true) }
    func testMuteQuietHoursAndDuplicateStillSilenceFailureAndExpiry() throws {
        for expire in [false, true] {
            try check(topic: expire ? "pending" : "status500", expire: expire, muted: true)
            try check(topic: expire ? "pending" : "status401", expire: expire, duplicate: true)
            try check(topic: expire ? "pending" : "status500", expire: expire, quiet: true)
            QuietHours().save()
        }
    }
    func testPlainMessageAndFetchedMessageKeepSameSound() throws {
        try check(topic: "success", direct: true)
        try check(topic: "success")
    }
}

private final class PollFallbackSoundHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfy.tests.auth-http")
    private var connections: [NWConnection] = []
    // Listener callbacks, receive callbacks and stop all serialize on queue.
    private var stopped = false
    private let checkRequestLine: (String, Bool) -> Void
    private let connectionAccepted: () -> Void
    private let receiveCompleted: () -> Void
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(checkRequestLine: @escaping (String, Bool) -> Void = { line, valid in XCTAssertTrue(valid, line) },
         connectionAccepted: @escaping () -> Void = {}, receiveCompleted: @escaping () -> Void = {}) throws {
        self.checkRequestLine = checkRequestLine
        self.connectionAccepted = connectionAccepted
        self.receiveCompleted = receiveCompleted
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            if case .ready = state { ready() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection)
            self.connectionAccepted()
        }
        listener.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard !self.stopped else { self.receiveCompleted(); return }
            var request = buffered
            request.append(data ?? Data())
            guard let delimiter = request.range(of: Data("\r\n".utf8)) else {
                if !complete, error == nil, let data, !data.isEmpty, request.count < 65536 {
                    self.receiveRequest(on: connection, buffered: request)
                } else {
                    // EOF/cancellation before a request line is not a malformed HTTP request.
                    connection.cancel()
                    self.receiveCompleted()
                }
                return
            }
            defer { self.receiveCompleted() }
            let line = String(decoding: request[..<delimiter.lowerBound], as: UTF8.self)
            self.checkRequestLine(line, line.contains("poll=1&id=authpoll1234"))
            if line.contains("/pending/") { return }
            if line.contains("/success/") {
                let body = Data("{\"id\":\"authpoll1234\",\"time\":1700000000,\"event\":\"message\",\"topic\":\"success\",\"message\":\"Fetched probe\",\"priority\":3}\n".utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let status = line.contains("status401") ? 401 : line.contains("status403") ? 403 : line.contains("status429") ? 429 : 500
            print("NSE_AUTH_HTTP \(line) response=\(status)")
            let response = Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

import XCTest
import UserNotifications
import CryptoKit
import Network
import UIKit
@testable import ntfy

final class BackgroundHTTPActionTests: XCTestCase {
    private func action(_ type: String = "http", id: String = UUID().uuidString, url: String? = nil) -> Action {
        Action(id: id, action: type, label: "Approve", url: url, method: "POST", headers: nil, body: nil, clear: nil)
    }

    private func userInfo(_ actions: [Action]) throws -> [AnyHashable: Any] {
        ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "background-actions",
         "message": "Approve request", "actions": String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)]
    }

    func testRegisteredIOSOptionsAndLegacyCategoryMigration() throws {
        let actions = [action(), action("view"), action("copy")]
        let message = try XCTUnwrap(Message.from(userInfo: userInfo(actions)))
        let content = UNMutableNotificationContent()
        let oldCanonical = actions.map { "\($0.id)\u{1f}\($0.label)" }.joined(separator: "\u{1e}")
        let oldID = "ntfyActions." + SHA256.hash(data: Data(oldCanonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let registered = expectation(description: "registered on worker")
        DispatchQueue.global().async {
            UNMutableNotificationContent.registerCategorySynchronously(UNNotificationCategory(identifier: oldID,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.label, options: .foreground) },
                intentIdentifiers: [], options: .customDismissAction))
            content.modify(message: message, baseUrl: "http://127.0.0.1")
            registered.fulfill()
        }
        wait(for: [registered], timeout: 10)
        XCTAssertNotEqual(content.categoryIdentifier, oldID, "new deliveries must not reuse the legacy foreground id")
        let read = expectation(description: "category options")
        UNUserNotificationCenter.current().getNotificationCategories { categories in
            let options = categories.first { $0.identifier == content.categoryIdentifier }?.actions.map(\.options)
            XCTAssertEqual(options, [.authenticationRequired, .foreground, .foreground])
            XCTAssertFalse(categories.contains { $0.identifier == oldID }, "prune unused legacy registrations")
            read.fulfill()
        }
        wait(for: [read], timeout: 5)
    }

    func testOptionsOnIOSAndMacAndDeterministicCategoryIDs() {
        let buttons = [action(id: "http"), action("view", id: "view"), action("copy", id: "copy")]
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons, onMac: false).map(\.options),
                       [.authenticationRequired, .foreground, .foreground])
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons, onMac: true).map(\.options),
                       [.foreground, .foreground, .foreground])
        for mac in [true, false] {
            let canonical = UNMutableNotificationContent.notificationActions(for: buttons, onMac: mac)
                .map { "\($0.identifier)\u{1f}\($0.title)\u{1f}\($0.options.rawValue)" }.joined(separator: "\u{1e}")
            let expected = "ntfyActions." + SHA256.hash(data: Data(canonical.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: mac), expected)
        }
        XCTAssertNotEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: false),
                          UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: true))
        var changed = buttons; changed[0].action = "view"
        XCTAssertNotEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: false),
                          UNMutableNotificationContent.actionCategoryIdentifier(for: changed, onMac: false))
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons + buttons, onMac: false).count, 4)
    }

    @MainActor
    private func checkCompletion(status: Int) throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let received = expectation(description: "real HTTP request received")
        server.received = { received.fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let delegate = AppDelegate()
        var starts = 0, ends = 0, completions = 0
        delegate.beginNotificationBackgroundTask = { _ in starts += 1; return UIBackgroundTaskIdentifier(rawValue: 42) }
        delegate.endNotificationBackgroundTask = { task in XCTAssertEqual(task.rawValue, 42); ends += 1 }
        let done = expectation(description: "delegate completes after HTTP response")
        delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
            notificationId: UUID().uuidString) {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(server.didRespond, "delegate finished while the request was still waiting for its response")
                completions += 1
                done.fulfill()
            }
        XCTAssertEqual(completions, 0, "HTTP completion must not run at dispatch")
        XCTAssertEqual(starts, 1, "hold process alive before dispatch")
        XCTAssertEqual(ends, 0)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(completions, 0, "server has not responded yet")
        server.respond(status: status)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(ends, 1)
    }

    @MainActor func testSuccessfulHTTPResponseFinishesBeforeDelegateCompletion() throws { try checkCompletion(status: 200) }
    @MainActor func testFailedHTTPResponseFinishesBeforeDelegateCompletion() throws { try checkCompletion(status: 401) }

    @MainActor
    func testRepeatTapAndCooldownRefusalComplete() throws {
        let button = action(url: "http://127.0.0.1:\(UInt16.random(in: 40000...60000))/approve")
        let info = try userInfo([button])
        let server = ActionExecutor.cooldownServer(for: try XCTUnwrap(ActionExecutor.makeHTTPRequest(button, baseUrl: nil)), baseUrl: nil)
        ServerCooldown.shared.limit(server: server, retryAfter: "60", condition: "time", kind: .action)
        XCTAssertNil(ServerCooldown.shared.claimAttempt(server: server, manual: true, kind: .action))
        let done = expectation(description: "refusal and executor repeat both complete")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            AppDelegate().handleNotificationResponse(userInfo: info, actionIdentifier: button.id,
                notificationId: UUID().uuidString) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }
    @MainActor
    func testExpirationCancelsPendingRequestAndEndsOnlyOnce() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let received = expectation(description: "request waiting for response")
        server.received = { received.fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let delegate = AppDelegate()
        var expire: (() -> Void)!, ends = 0, completions = 0
        delegate.beginNotificationBackgroundTask = { expire = $0; return UIBackgroundTaskIdentifier(rawValue: 43) }
        delegate.endNotificationBackgroundTask = { _ in ends += 1 }
        let duplicate = expectation(description: "no second completion after cancellation callback")
        duplicate.isInverted = true
        delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
            notificationId: UUID().uuidString) {
                completions += 1
                if completions > 1 { duplicate.fulfill() }
            }
        wait(for: [received], timeout: 5)
        XCTAssertEqual(completions, 0)
        expire()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(ends, 1)
        server.respond(status: 200)
        wait(for: [duplicate], timeout: 0.5)
        XCTAssertEqual(ends, 1)
    }

    func testCompletionWaitsThroughRetry() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        let first = expectation(description: "first request"), second = expectation(description: "retry request")
        var requests = 0
        server.received = { requests += 1; (requests == 1 ? first : second).fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let done = expectation(description: "completed after retry response")
        var completed = false
        ActionExecutor.execute(button) { completed = true; done.fulfill() }
        wait(for: [first], timeout: 5)
        server.respond(status: 503)
        wait(for: [second], timeout: 5)
        XCTAssertFalse(completed)
        server.respond(status: 200)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(requests, 2)
    }

    func testCancellationWhileWaitingToRetryPreventsAnotherRequest() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        let first = expectation(description: "first request"), extra = expectation(description: "no request after cancel")
        extra.isInverted = true
        var requests = 0
        server.received = { requests += 1; (requests == 1 ? first : extra).fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let done = expectation(description: "cancelled retry completes")
        let execution = ActionExecutor.execute(button) { done.fulfill() }
        wait(for: [first], timeout: 5)
        server.respond(status: 503)
        // Give URLSession its refusal so cancellation exercises the scheduled retry, not the socket.
        let pause = expectation(description: "response consumed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pause.fulfill() }
        wait(for: [pause], timeout: 2)
        execution.cancel()
        wait(for: [done, extra], timeout: 1.5)
    }

    @MainActor
    func testInvalidHTTPAndCopyCompleteWithoutLeakingBackgroundTask() throws {
        for button in [action(), action("copy")] {
            let delegate = AppDelegate()
            var starts = 0, ends = 0
            delegate.beginNotificationBackgroundTask = { _ in starts += 1; return UIBackgroundTaskIdentifier(rawValue: 44) }
            delegate.endNotificationBackgroundTask = { _ in ends += 1 }
            let done = expectation(description: "invalid or foreground action completes")
            delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
                notificationId: UUID().uuidString) { done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(starts, button.action == "http" ? 1 : 0)
            XCTAssertEqual(ends, starts)
        }
    }

}

// Adapted from NSEAuthLoopbackServer's Network listener and complete-request-line framing.
// The original fixture is private in ntfyTests.swift; this fixture holds responses until released.
private final class ActionLoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfy.tests.action-http")
    private var connection: NWConnection?
    private let lock = NSLock()
    private var responded = false
    private var stopped = false
    var received: () -> Void = {}
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var didRespond: Bool { lock.lock(); defer { lock.unlock() }; return responded }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard !self.stopped else { return }
            var request = buffered
            request.append(data ?? Data())
            if let delimiter = request.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: request[..<delimiter.lowerBound], as: UTF8.self)
                XCTAssertEqual(line, "POST /approve HTTP/1.1")
                print("ACTION_HTTP_RECEIVED \(line)")
                self.received()
            } else if !complete, error == nil, let data, !data.isEmpty {
                self.receive(connection, buffered: request)
            }
        }
    }
    func respond(status: Int) {
        queue.async {
            self.lock.lock(); self.responded = true; self.lock.unlock()
            print("ACTION_HTTP_RESPONSE \(status)")
            let connection = self.connection
            connection?.send(content: Data("HTTP/1.1 \(status) Result\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                completion: .contentProcessed { _ in connection?.cancel() })
        }
    }
    func stop() {
        queue.sync { stopped = true; listener.cancel(); connection?.cancel() }
    }
}

import XCTest
import CoreData
@testable import ntfy

final class ClearThroughTests: XCTestCase {
    private let base = "https://bulk.example"
    private var coordinator: ClearThroughCoordinator!

    private func clear(_ id: String = "AbCdEf123456", sequence: String = "opaque-sequence") -> ClearRequest {
        ClearRequest(baseUrl: base, topic: "test-topic", sequence: sequence,
                     user: BasicUser(username: "reader", password: "topic-only"), messageId: id)
    }
    private func intent(_ boundary: ClearRequest? = nil, candidates: [ClearRequest]? = nil) -> ClearThroughIntent {
        let boundary = boundary ?? clear()
        return ClearThroughIntent(boundary: boundary, candidates: candidates ?? [boundary], known: candidates ?? [boundary])
    }
    private func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
    private func make(supported: Bool = true, preflight: Bool = true, invalidate: @escaping (String) -> Void = { _ in },
                      cooldown: ServerCooldown = ServerCooldown(defaults: nil),
                      transport: @escaping ClearThroughCoordinator.Transport) -> ClearThroughCoordinator {
        var needsPreflight = preflight
        return ClearThroughCoordinator(cooldown: cooldown, discover: { _, _, done in done(ServerCapabilities(clearThrough: supported)) },
                                invalidate: invalidate, transport: { request, done in
            if needsPreflight {
                needsPreflight = false
                XCTAssertNotEqual(request.httpMethod, "PUT")
                done(self.event(), self.response(request, status: 200), nil)
            } else { transport(request, done) }
        }, schedule: { _, work in work() })
    }
    private func receipt(_ id: String = "AbCdEf123456") -> Data { Data("{\"cleared\":1,\"through_id\":\"\(id)\"}".utf8) }
    private func event(_ event: String = "message", id: String = "AbCdEf123456", sequence: String = "opaque-sequence") -> Data {
        Data("{\"id\":\"\(id)\",\"time\":100,\"event\":\"\(event)\",\"topic\":\"test-topic\",\"sequence_id\":\"\(sequence)\"}\n".utf8)
    }

    func testOneRequestUsesBoundaryMessageIDAndOnlyTopicCredentials() throws {
        let finished = expectation(description: "bulk sent")
        coordinator = make { request, done in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://bulk.example/test-topic/opaque-sequence/clear-through")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-NtfyMe-Through-ID"), "AbCdEf123456")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.clear().user?.toHeader())
            XCTAssertEqual(request.httpBody?.count, 0)
            done(self.receipt(), self.response(request, status: 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .sent = result else { return XCTFail("bulk should succeed") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testUnsupportedDiscoveryRetainsLegacyFallbackWithoutBulkRequest() {
        let finished = expectation(description: "stock fallback")
        coordinator = make(supported: false) { _, _ in XCTFail("stock does not receive extension requests") }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("stock should use individual clears") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func test404405InvalidateAnd413FallbackWithoutRetry() {
        for status in [404, 405, 413] {
            let finished = expectation(description: "fallback \(status)")
            var sends = 0; var invalidated = 0
            coordinator = make(invalidate: { server in XCTAssertEqual(server, self.base); invalidated += 1 }) { request, done in
                sends += 1; done(Data(), self.response(request, status: status), nil)
            }
            coordinator.send(intent()) { result in
                guard case .fallback = result else { return XCTFail("expected safe fallback") }
                XCTAssertEqual(sends, 1); XCTAssertEqual(invalidated, status == 413 ? 0 : 1)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func test400AuthAnd429NeverFanOutToIndividualClears() {
        for status in [400, 401, 403, 429] {
            let finished = expectation(description: "deferred \(status)")
            let cooldown = ServerCooldown(defaults: nil)
            var sends = 0
            coordinator = make(cooldown: cooldown) { request, done in
                sends += 1
                done(Data(), self.response(request, status: status, headers: ["Retry-After-Condition": "request-change"]), nil)
            }
            coordinator.send(intent()) { result in
                guard case .deferred = result else { return XCTFail("failure must not fan out") }
                XCTAssertEqual(sends, 1)
                if status == 429 { XCTAssertFalse(cooldown.claim(server: self.base, manual: false, kind: .clearThrough)) }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func test409PollsThenRetriesOnlyTwiceBeforePacedFallback() {
        let finished = expectation(description: "bounded boundary retry")
        var methods: [String] = []
        coordinator = make { request, done in
            methods.append(request.httpMethod ?? "GET")
            done(request.httpMethod == "PUT" ? Data() : self.event(),
                 self.response(request, status: request.httpMethod == "PUT" ? 409 : 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("unavailable boundary should fall back") }
            XCTAssertEqual(methods, ["PUT", "GET", "PUT", "GET", "PUT", "GET"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testLostResponsePollSeesCommittedControlAndDoesNotPublishAgain() {
        for status in [0, 500, 503] {
            let finished = expectation(description: "reconcile lost response \(status)")
            var methods: [String] = []
            coordinator = make { request, done in
                methods.append(request.httpMethod ?? "GET")
                if request.httpMethod == "PUT" {
                    done(nil, status == 0 ? nil : self.response(request, status: status), status == 0 ? URLError(.timedOut) : nil)
                } else { done(self.event("message_clear", id: "ClrAbC123456"), self.response(request, status: 200), nil) }
            }
            coordinator.send(intent()) { result in
                guard case .sent = result else { return XCTFail("poll proved clear committed") }
                XCTAssertEqual(methods, ["PUT", "GET"])
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func testLostResponseWithNoControlsPollsBeforeEachBoundedRetryAndNeverFallbacks() {
        let finished = expectation(description: "bounded uncertain transaction")
        var methods: [String] = []
        coordinator = make { request, done in
            methods.append(request.httpMethod ?? "GET")
            done(request.httpMethod == "PUT" ? Data() : self.event(),
                 self.response(request, status: request.httpMethod == "PUT" ? 500 : 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .deferred = result else { return XCTFail("uncertain transaction cannot fan out") }
            XCTAssertEqual(methods, ["PUT", "GET", "PUT", "GET", "PUT", "GET"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testReconciliationPoll429StopsWithoutResending() {
        let finished = expectation(description: "poll honors quota")
        var sends = 0
        coordinator = make { request, done in
            sends += 1
            done(nil, self.response(request, status: sends == 1 ? 500 : 429,
                                   headers: ["Retry-After-Condition": "state-change"]), nil)
        }
        coordinator.send(intent()) { result in
            guard case .deferred = result else { return XCTFail("poll quota cannot cause fallback") }
            XCTAssertEqual(sends, 2); finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testEqualSecondBoundaryUsesLastKnownMessageInServerOrder() {
        let first = clear("ZzzzzZ123456", sequence: "larger-lexical-id")
        let last = clear("AaaaaA123456", sequence: "smaller-lexical-id")
        let finished = expectation(description: "server order boundary")
        var methods: [String] = []
        coordinator = make(preflight: false) { request, done in
            methods.append(request.httpMethod ?? "GET")
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-NtfyMe-Through-ID"), last.messageId)
                XCTAssertTrue(request.url!.path.contains(last.sequence))
                done(self.receipt(last.messageId!), self.response(request, status: 200), nil)
            } else {
                done(self.event(id: first.messageId!, sequence: first.sequence) + self.event(id: last.messageId!, sequence: last.sequence),
                     self.response(request, status: 200), nil)
            }
        }
        coordinator.send(intent(first, candidates: [first, last])) { result in
            guard case .sent = result else { return XCTFail("tie should resolve") }
            XCTAssertEqual(methods, ["GET", "PUT"]); finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testAbsentTieCandidatesFallbackInsteadOfGuessing() {
        let finished = expectation(description: "missing boundary")
        coordinator = make(preflight: false) { request, done in
            XCTAssertNotEqual(request.httpMethod, "PUT")
            done(Data(), self.response(request, status: 200), nil)
        }
        coordinator.send(intent(candidates: [clear(), clear("OtherA123456", sequence: "other")])) { result in
            guard case .fallback = result else { return XCTFail("missing candidates are not ordered") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testLatePollReconciliationRetainsSuccessCallbackAndReportsItOnlyOnce() {
        let deferred = expectation(description: "uncertain response deferred")
        let reconciled = expectation(description: "later poll proves success")
        let duplicate = expectation(description: "no duplicate success or deferred callback")
        duplicate.isInverted = true
        var sends = 0; var successes = 0; var deferrals = 0
        coordinator = make { _, done in
            sends += 1
            done(nil, nil, URLError(.timedOut))
        }
        let controls = [Message(id: "ClrAbC123456", time: 101, event: "message_clear", topic: "test-topic", sequenceID: "opaque-sequence")]
        coordinator.send(intent()) { result in
            switch result {
            case .deferred:
                deferrals += 1
                if deferrals == 1 { deferred.fulfill() } else { duplicate.fulfill() }
                self.coordinator.reconcile(baseUrl: self.base, topic: "test-topic", messages: controls)
                self.coordinator.reconcile(baseUrl: self.base, topic: "test-topic", messages: controls)
            case .sent:
                successes += 1
                if successes == 1 { reconciled.fulfill() } else { duplicate.fulfill() }
            case .fallback: XCTFail("lost-response intent must not fan out")
            }
        }
        wait(for: [deferred, reconciled], timeout: 2)
        wait(for: [duplicate], timeout: 0.1)
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(deferrals, 1)
    }

    func testTopicReadCommitsLocallyWhileDiscoveryWaitsAndUsesOneBulkRequest() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: base, topic: "test-topic")
        defer { store.delete(subscription: sub); store.clearThrough = nil }
        store.clearPublisher = { _, _ in XCTFail("advertised support uses one bulk request") }
        store.topicNotificationRemover = { _, _, _, _ in }
        store.wakePublisher = { _, done in done() }
        store.save(notificationsFromMessages: [Message(id: "OldMsg123456", time: 90, event: "message", topic: "test-topic"),
            Message(id: "AbCdEf123456", time: 100, event: "message", topic: "test-topic")], withSubscription: sub)
        let discovering = expectation(description: "discover started")
        let finished = expectation(description: "one bulk completed")
        var discovery: ((ServerCapabilities) -> Void)?
        var sends = 0
        coordinator = ClearThroughCoordinator(cooldown: ServerCooldown(defaults: nil), discover: { _, _, done in
            discovery = done; discovering.fulfill()
        }, transport: { request, done in
            if request.httpMethod != "PUT" {
                done(self.event(id: "OldMsg123456", sequence: "OldMsg123456") + self.event(sequence: "AbCdEf123456"), self.response(request, status: 200), nil)
                return
            }
            sends += 1
            XCTAssertTrue(request.url!.path.hasSuffix("/AbCdEf123456/clear-through"))
            done(self.receipt(), self.response(request, status: 200), nil)
            finished.fulfill()
        })
        store.clearThrough = coordinator
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(store.unreadCount(baseUrl: base, topic: "test-topic"), 0)
        wait(for: [discovering], timeout: 2)
        XCTAssertEqual(sends, 0)
        discovery?(ServerCapabilities(clearThrough: true))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(sends, 1)
    }
    func testTopicIntentOverTenRowsDoesNotReconcileFromOnlyTenClearControls() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: base, topic: "test-topic")
        defer { store.delete(subscription: sub); store.clearThrough = nil }
        store.clearPublisher = { _, _ in XCTFail("bulk retry cannot fan out") }
        store.topicNotificationRemover = { _, _, _, _ in }
        let finished = expectation(description: "all read intent retained")
        store.wakePublisher = { _, done in done(); finished.fulfill() }
        let messages = (0..<12).map { index in
            Message(id: String(format: "Read%08d", index), time: Int64(100 + index), event: "message", topic: "test-topic")
        }
        store.save(notificationsFromMessages: messages, withSubscription: sub)
        var methods: [String] = []
        var preflight = true
        coordinator = make(preflight: false) { request, done in
            if preflight {
                preflight = false
                let originals = messages.map { "{\"id\":\"\($0.id)\",\"time\":\($0.time),\"event\":\"message\",\"topic\":\"test-topic\"}\n" }.joined()
                done(Data(originals.utf8), self.response(request, status: 200), nil)
                return
            }
            methods.append(request.httpMethod ?? "GET")
            if methods.count == 1 { done(nil, nil, URLError(.timedOut)) }
            else if request.httpMethod != "PUT" {
                // A previous action cleared the newest ten, while two older read rows remain.
                // A capped reconciliation snapshot would falsely declare this topic fully clear.
                let originals = messages.map { "{\"id\":\"\($0.id)\",\"time\":\($0.time),\"event\":\"message\",\"topic\":\"test-topic\"}\n" }.joined()
                let controls = messages.suffix(10).enumerated().map { index, message in
                    "{\"id\":\"Ctrl\(String(format: "%08d", index))\",\"time\":200,\"event\":\"message_clear\",\"topic\":\"test-topic\",\"sequence_id\":\"\(message.id)\"}\n"
                }.joined()
                done(Data((originals + controls).utf8), self.response(request, status: 200), nil)
            } else {
                XCTAssertEqual(methods, ["PUT", "GET", "PUT"])
                done(self.receipt(messages.last!.id), self.response(request, status: 200), nil)
            }
        }
        store.clearThrough = coordinator
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(store.unreadCount(baseUrl: base, topic: "test-topic"), 0)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(methods, ["PUT", "GET", "PUT"])
    }

    func testTopicReadStoresPreflightBeforeClearAndKeepsEarlierMissingMessageUnread() {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: base, topic: "test-topic")
        defer { store.delete(subscription: sub); store.clearThrough = nil }
        let fallback = expectation(description: "only known read row is cleared")
        store.clearPacer = ClearPacer(cooldown: ServerCooldown(defaults: nil))
        store.clearPublisher = { request, done in
            XCTAssertEqual(request.messageId, "AbCdEf123456")
            XCTAssertEqual(store.unreadCount(baseUrl: self.base, topic: "test-topic"), 1)
            fallback.fulfill(); done(.sent)
        }
        store.topicNotificationRemover = { _, _, _, _ in }
        store.wakePublisher = { _, done in done() }
        store.save(notificationsFromMessages: [Message(id: "AbCdEf123456", time: timestamp, event: "message", topic: "test-topic")], withSubscription: sub)
        let polled = expectation(description: "full poll after immediate local read")
        var preflightDone: ((Data?, URLResponse?, Error?) -> Void)?
        var preflightRequest: URLRequest?
        coordinator = make(preflight: false) { request, done in
            XCTAssertNotEqual(request.httpMethod, "PUT", "newly discovered unread row must never be included in bulk")
            guard request.httpMethod != "PUT" else { done(self.receipt(), self.response(request, status: 200), nil); return }
            XCTAssertTrue(request.url!.absoluteString.contains("since=all"))
            preflightRequest = request; preflightDone = done; polled.fulfill()
        }
        store.clearThrough = coordinator
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(store.unreadCount(baseUrl: base, topic: "test-topic"), 0)
        wait(for: [polled], timeout: 2)
        guard let preflightRequest, let preflightDone else { wait(for: [fallback], timeout: 0.1); return }
        let earlier = Data(String(decoding: event(id: "Missed123456", sequence: "Missed123456"), as: UTF8.self).replacingOccurrences(of: "\"time\":100", with: "\"time\":\(timestamp - 10)").utf8)
        let boundary = Data(String(decoding: event(sequence: "AbCdEf123456"), as: UTF8.self)
            .replacingOccurrences(of: "\"time\":100", with: "\"time\":\(timestamp)").utf8)
        preflightDone(earlier + boundary, response(preflightRequest, status: 200), nil)
        wait(for: [fallback], timeout: 2)
        XCTAssertEqual(store.unreadCount(baseUrl: base, topic: "test-topic"), 1)
    }

    func testPreflightMustStoreSuccessfullyBeforeAnyClear() {
        let finished = expectation(description: "failed save defers bulk")
        coordinator = make(preflight: false) { request, done in
            XCTAssertNotEqual(request.httpMethod, "PUT")
            done(self.event(), self.response(request, status: 200), nil)
        }
        coordinator.send(intent(), storeMessages: { _ in false }) { result in
            guard case .deferred = result else { return XCTFail("failed local save cannot authorize a clear") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testReplacingIntentDuringDiscoveryRetainsBothLegacyFallbacks() {
        let discovering = expectation(description: "first discovery")
        let finished = expectation(description: "both fallback callbacks")
        finished.expectedFulfillmentCount = 2
        var discoveries: [(ServerCapabilities) -> Void] = []
        coordinator = ClearThroughCoordinator(cooldown: ServerCooldown(defaults: nil), discover: { _, _, done in
            discoveries.append(done)
            if discoveries.count == 1 { discovering.fulfill() }
            else { done(.unsupported) }
        }, transport: { _, _ in XCTFail("stock has no extension requests") })
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("unsent read intent needs legacy fallback") }
            finished.fulfill()
        }
        wait(for: [discovering], timeout: 2)
        coordinator.send(intent(clear("OtherA123456", sequence: "other"))) { result in
            guard case .fallback = result else { return XCTFail("stock needs legacy fallback") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        discoveries.first?(.unsupported)
    }

    func testOversizePreflightFallsBackWithoutClear() {
        let finished = expectation(description: "oversize full poll uses known individual clears")
        coordinator = make(preflight: false) { request, done in
            XCTAssertNotEqual(request.httpMethod, "PUT")
            done(Data(repeating: 32, count: 4_000_001), self.response(request, status: 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("oversize selection must retain legacy fallback") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func test413RemembersTopicForFiveMinutesWithoutMoreDiscoveryOrRequests() {
        let first = expectation(description: "first oversized boundary")
        let second = expectation(description: "remembered oversized topic")
        var sends = 0
        coordinator = make { request, done in
            sends += 1
            done(nil, self.response(request, status: 413), nil)
        }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("413 needs legacy fallback") }
            first.fulfill()
        }
        wait(for: [first], timeout: 2)
        coordinator.send(intent(clear("OtherA123456", sequence: "other"))) { result in
            guard case .fallback = result else { return XCTFail("oversized topic should remain on paced clears") }
            second.fulfill()
        }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(sends, 1)
    }

}

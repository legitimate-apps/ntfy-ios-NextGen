import XCTest
@testable import ntfy

final class ServerContractTests: XCTestCase {
    private func response(_ headers: [String: String], status: Int = 429) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://server.invalid/t")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testActionRejectsLongTimedRetryAndReportsWhenToTryAgain() {
        let headers = ["Retry-After": "72000", "Retry-After-Condition": "time"]
        XCTAssertNil(ActionExecutor.retryDelay(response: response(headers), error: nil, attempt: 1))
        XCTAssertEqual(ActionExecutor.httpActionResult(response: response(headers), error: nil),
                       .failure("The server is limiting this action. Try again in 72000 seconds."))
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After": "10", "Retry-After-Condition": "time"]), error: nil, attempt: 1), 10)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After": "72000"]), error: nil, attempt: 1), 10)
    }

    func testActionGateUsesDestinationAndSharesOnlyThePublishBudget() {
        let own = URLRequest(url: URL(string: "https://self.example/ntfy/topic")!)
        XCTAssertEqual(ActionExecutor.cooldownServer(for: own, baseUrl: "https://self.example/ntfy"), "https://self.example/ntfy")
        let other = URLRequest(url: URL(string: "https://other.example/action?secret=private")!)
        XCTAssertEqual(ActionExecutor.cooldownServer(for: other, baseUrl: "https://self.example/ntfy"), "https://other.example")
        let gate = ServerCooldown(defaults: nil)
        gate.limit(server: "https://other.example", retryAfter: "72000", condition: "time", kind: .action)
        XCTAssertFalse(gate.claim(server: "https://other.example", manual: false, kind: .clear))
        XCTAssertTrue(gate.claim(server: "https://other.example", manual: false, kind: .poll))
        XCTAssertTrue(gate.claim(server: "https://self.example/ntfy", manual: false, kind: .action))
    }

    func testRelayReadsSurviveUnrelatedPublishRefusalAndTestPublishRespectsOwnBudget() {
        let cooldown = ServerCooldown(defaults: nil)
        cooldown.limit(server: Config.appBaseUrl, retryAfter: "72000", condition: "time", kind: .clear)
        cooldown.limit(server: "https://self.example", retryAfter: "72000", condition: "time", kind: .clearThrough)
        var reads = 0
        let check = RelayCheck(cooldown: cooldown, discover: { $0(true) }, read: { request, done in
            reads += 1
            done(Data("{\"relayed\":false,\"relayed_at\":null,\"window_seconds\":120}".utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { _, action in action() })
        check.prepare(baseUrl: "https://self.example", topic: "topic")
        let prepared = expectation(description: "relay capability callback")
        DispatchQueue.main.async { prepared.fulfill() }
        wait(for: [prepared], timeout: 2)
        XCTAssertEqual(check.state, .consent)
        check.approve { _ in XCTFail("Daily publish refusal must prevent the test message") }
        let done = expectation(description: "relay baseline callback")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(check.state.message?.contains("No test message was sent") == true)
    }

    func testActionDoesNotTimerRetryStateOrRequestChanges() {
        for condition in ["state-change", "request-change"] {
            XCTAssertNil(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": condition]), error: nil, attempt: 1))
        }
        XCTAssertEqual(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 2), 2)
        XCTAssertNil(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 3))
    }

    func testUnknownConditionsAnd503KeepStockActionBehavior() {
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": "future"]), error: nil, attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": "state-change"], status: 503), error: nil, attempt: 1), 1)
        XCTAssertNil(RetryDirective.parse(condition: "time", retryAfter: "nan"))
        XCTAssertEqual(RetryDirective.parse(condition: "time", retryAfter: "9999999999999999999"), .requestChange)
    }

    func testPublishDailyResetIsMonotonicPersistedAndNeverGatesReads() {
        var wall = Date(timeIntervalSince1970: 1_700_000_000)
        var uptime: TimeInterval = 100
        let suite = "ServerContractTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = ServerCooldown(defaults: defaults, now: { wall }, uptime: { uptime })
        cooldown.limit(server: "https://s.invalid", retryAfter: "72000", condition: "time", kind: .clear)
        for kind: ServerCooldown.Kind in [.clear, .clearThrough, .action, .publish] {
            XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: true, kind: kind))
        }
        for kind: ServerCooldown.Kind in [.poll, .relay] {
            XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: kind))
        }
        wall += 80000
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clear))
        uptime += 72000
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clear))
        wall = Date(timeIntervalSince1970: 1_700_000_010)
        let relaunched = ServerCooldown(defaults: defaults, now: { wall }, uptime: { 200 })
        XCTAssertGreaterThan(relaunched.deadline(for: "https://s.invalid", kind: .clear).timeIntervalSince(wall), 71000)
        XCTAssertTrue(relaunched.claim(server: "https://s.invalid", manual: false))
    }

    func testPollConditionsRecoverAutomaticallyWithinStockBackoffAndAllowManualProbe() {
        for condition in ["state-change", "request-change", "time"] {
            var date = Date(timeIntervalSince1970: 1_700_000_000)
            let cooldown = ServerCooldown(defaults: nil, now: { date })
            for expected: TimeInterval in [60, 120, 240, 480, 960, 1920, 3600, 3600] {
                cooldown.limit(server: condition, retryAfter: nil, condition: condition)
                XCTAssertEqual(cooldown.deadline(for: condition).timeIntervalSince(date), expected)
                XCTAssertFalse(cooldown.claim(server: condition, manual: false))
                date += expected
                XCTAssertTrue(cooldown.claim(server: condition, manual: false))
            }
            cooldown.limit(server: condition, retryAfter: "72000", condition: "time")
            XCTAssertEqual(cooldown.deadline(for: condition).timeIntervalSince(date), 3600)
            XCTAssertTrue(cooldown.claim(server: condition, manual: true))
            XCTAssertFalse(cooldown.claim(server: condition, manual: true))
        }
    }

    func testSubscriptionManagerAutomaticAndSilentPollsRecoverAfterNonTimeRefusal() {
        for condition in ["state-change", "request-change"] {
            let store = Store(inMemory: true)
            let subscription = store.saveSubscription(baseUrl: "https://condition.invalid", topic: "topic")
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            let polling = PollCoordinator(defaults: nil, now: { clock })
            var manager = SubscriptionManager(store: store, polling: polling)
            var fetches = 0
            manager.fetch = { _, done in
                fetches += 1
                if fetches == 1 { done(nil, PollHTTPError(status: 429, retryAfter: nil, retryCondition: condition)) }
                else { done([], nil) }
            }
            manager.pollWithOutcome(subscription) { XCTAssertTrue($0.attempted) }
            clock += 59
            manager.pollWithOutcome(subscription) { XCTAssertFalse($0.attempted) }
            clock += 1
            XCTAssertTrue(manager.handleSilentWake(userInfo: ["event": "message_clear", "topic": firebaseTopic(baseUrl: subscription.baseUrl!, topic: "topic")]) { _ in })
            XCTAssertEqual(fetches, 2)
            manager.pollWithOutcome(subscription) { XCTAssertTrue($0.attempted) }
            XCTAssertEqual(fetches, 3)
        }
    }

    func testPersistedGatesAreBoundedAndOldGlobalExtensionGateIsDiscarded() {
        let suite = "gate-upgrade-\(UUID())", date = Date(timeIntervalSince1970: 1_700_000_000)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["https://s.invalid": date.timeIntervalSince1970 + 9e9], forKey: "serverExtensionCooldowns118")
        let upgraded = ServerCooldown(defaults: defaults, now: { date })
        XCTAssertTrue(upgraded.claim(server: "https://s.invalid", manual: false))
        upgraded.limit(server: "https://s.invalid", retryAfter: "9000000000", condition: "time", kind: .clear)
        let relaunched = ServerCooldown(defaults: defaults, now: { date })
        XCTAssertLessThanOrEqual(relaunched.deadline(for: "https://s.invalid", kind: .clear).timeIntervalSince(date), 86400)
        XCTAssertTrue(relaunched.claim(server: "https://s.invalid", manual: false))
    }

    func testExtensionInitializationCannotOverwriteANewerAppRefusal() {
        let suite = "startup-race-\(UUID())", date = Date(timeIntervalSince1970: 1_700_000_000)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ServerCooldown(defaults: defaults, now: { date })
        app.limit(server: "https://first.invalid", retryAfter: "60", condition: "time", kind: .clear)
        _ = ServerCooldown(defaults: defaults, now: { date }, uptime: {
            // A response arrives in the app while the extension reconstructs its own snapshot.
            app.limit(server: "https://newer.invalid", retryAfter: "72000", condition: "time", kind: .clear)
            return 10
        })
        let relaunched = ServerCooldown(defaults: defaults, now: { date })
        XCTAssertFalse(relaunched.claim(server: "https://newer.invalid", manual: false, kind: .clear))
        XCTAssertTrue(relaunched.claim(server: "https://newer.invalid", manual: false, kind: .poll))
    }

    func testSuccessfulClearCannotResetPollBackoffOrEraseAnotherBudgetGate() {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let cooldown = ServerCooldown(defaults: nil, now: { date })
        cooldown.limit(server: "https://s.invalid", retryAfter: nil)
        let clear = cooldown.claimAttempt(server: "https://s.invalid", manual: false, kind: .clear)!
        cooldown.succeeded(server: "https://s.invalid", attempt: clear)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false))
        date += 60
        cooldown.limit(server: "https://s.invalid", retryAfter: nil)
        XCTAssertEqual(cooldown.deadline(for: "https://s.invalid").timeIntervalSince(date), 120)
    }

    func testConditionClearStopsQueuedRequestsOnThatServer() {
        let cooldown = ServerCooldown(defaults: nil)
        let pacer = ClearPacer(cooldown: cooldown)
        var complete: ((ClearOutcome) -> Void)?
        var sent = 0
        var finished = 0
        let requests = (0..<3).map { ClearRequest(baseUrl: "https://s.invalid", topic: "t", sequence: "id\($0)", user: nil) }
        pacer.send(requests, via: { _, done in sent += 1; complete = done }) { _, _ in finished += 1 }
        complete?(.conditionLimited(.stateChange))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(finished, 3)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clear))
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false), "a refused clear must not starve admissible GET polls")
    }

    func testExplicitClearCanProbeChangedServerStateWithoutChangingStockBrake() {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let cooldown = ServerCooldown(defaults: nil, now: { date })
        let pacer = ClearPacer(cooldown: cooldown)
        pacer.now = { date }
        let request = ClearRequest(baseUrl: "https://clear-probe.invalid", topic: "topic", sequence: "id", user: nil)
        pacer.send([request], via: { _, done in done(.conditionLimited(.stateChange)) }) { _, _ in }
        date += 60
        var sent = 0
        pacer.send([request], via: { _, done in sent += 1; done(.sent) }) { _, success in XCTAssertTrue(success) }
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(cooldown.claim(server: request.baseUrl, manual: false, kind: .clear))
        cooldown.limit(server: request.baseUrl, retryAfter: "600", kind: .clear)
        date += 60
        pacer.send([request], via: { _, _ in XCTFail("stock timed brake still drops queued clears") }) { _, success in XCTAssertFalse(success) }
    }

    func testNonTimeManualGateCanBeInspectedBeforeConsumingOneProbe() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cooldown = ServerCooldown(defaults: nil, now: { date })
        cooldown.limit(server: "https://relay-probe.invalid", retryAfter: nil, condition: "state-change", kind: .relay)
        XCTAssertTrue(cooldown.claim(server: "https://relay-probe.invalid", manual: true, kind: .relay, consumingProbe: false))
        XCTAssertTrue(cooldown.claim(server: "https://relay-probe.invalid", manual: true, kind: .relay))
        XCTAssertFalse(cooldown.claim(server: "https://relay-probe.invalid", manual: true, kind: .relay))
        XCTAssertFalse(cooldown.claim(server: "https://relay-probe.invalid", manual: false, kind: .relay))
    }

    func testMarkReadFailureSignalDoesNotChangeTopicDeliveryHealth() {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://auth-health.invalid", topic: "topic")
        let request = store.pollRequest(for: subscription)!
        let monitor = DeliveryHealthMonitor()
        monitor.register(request)
        let key = subscription.objectID.uriRepresentation().absoluteString
        for failure: PollFailure in [.unauthorized, .rateLimited, .other] {
            NotificationCenter.default.post(name: Foundation.Notification.Name("ntfyClearThroughFailure"), object: nil,
                userInfo: ["baseUrl": request.baseUrl, "topic": "topic", "failure": failure])
        }
        XCTAssertNil(monitor.topics[key])
        XCTAssertFalse(monitor.known.contains(key))
    }

    func testDiscoveryRequiresHTTPSAndKeepsTimedGateAcrossCacheInstances() {
        let cooldown = ServerCooldown(defaults: nil)
        var sends = 0
        func cache() -> ServerCapabilitiesCache {
            ServerCapabilitiesCache(cooldown: cooldown, transport: { request, done in
                sends += 1
                done(nil, HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After-Condition": "time", "Retry-After": "72000"]), nil)
            })
        }
        cache().discover(baseUrl: "http://self-host.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 0)
        cache().discover(baseUrl: "https://rate-discovery.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 1)
        cache().discover(baseUrl: "https://rate-discovery.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 1)
    }

    func testClearBudgetsShareGatesWhilePollsAndRelayRemainAdmissible() {
        let cooldown = ServerCooldown(defaults: nil)
        cooldown.limit(server: "https://s.invalid", retryAfter: nil, condition: "request-change", kind: .clearThrough)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clearThrough))
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .poll))
        cooldown.requestChanged(server: "https://s.invalid", kind: .clearThrough)
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clearThrough))
        cooldown.limit(server: "https://s.invalid", retryAfter: "72000", condition: "time", kind: .clearThrough)
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: true, kind: .poll))
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .relay))
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clear))
    }

    func testCapabilitiesExplicitVersionsAndLimits() {
        func decode(_ value: String) -> ServerCapabilities { ServerCapabilities.decode(Data(value.utf8)) }
        XCTAssertTrue(decode(Self.document).clearThrough)
        XCTAssertTrue(decode(Self.document).relayCheck)
        XCTAssertEqual(decode(Self.document.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")), .unsupported)
        XCTAssertFalse(decode(Self.document.replacingOccurrences(of: "\"relay_check\":1", with: "\"relay_check\":2")).relayCheck)
        XCTAssertFalse(decode(Self.document.replacingOccurrences(of: "\"clear_max_rows\":1000", with: "\"clear_max_rows\":2000")).clearThrough)
        XCTAssertEqual(decode("{\"version\":true,\"clear_through\":true}"), .unsupported)
        XCTAssertEqual(decode("<html>login</html>"), .unsupported)
    }

    static let document = "{\"version\":1,\"retry_after\":1,\"relay_check\":1,\"relay_window_seconds\":120,\"clear_through\":true,\"clear_max_sequences\":100,\"clear_max_rows\":1000}"

    func testDiscoverySingleFlightCachesNegativeForADayAndExpiresPerServer() {
        var clock: TimeInterval = 10
        var count = 0
        var reply: ((Data?, URLResponse?, Error?) -> Void)?
        let cache = ServerCapabilitiesCache(now: { clock }, wallTime: { clock }, transport: { _, completion in count += 1; reply = completion })
        var results = 0
        cache.discover(baseUrl: "https://stock.invalid") { XCTAssertEqual($0, .unsupported); results += 1 }
        cache.discover(baseUrl: "https://stock.invalid") { XCTAssertEqual($0, .unsupported); results += 1 }
        XCTAssertEqual(count, 1)
        reply?(nil, HTTPURLResponse(url: URL(string: "https://stock.invalid/v1/ntfyme/capabilities")!, statusCode: 404, httpVersion: nil, headerFields: nil), nil)
        XCTAssertEqual(results, 2)
        cache.discover(baseUrl: "https://stock.invalid") { _ in results += 1 }
        XCTAssertEqual(count, 1)
        clock += 86400
        cache.discover(baseUrl: "https://stock.invalid") { _ in }
        XCTAssertEqual(count, 2)
        cache.discover(baseUrl: "https://other.invalid") { _ in }
        XCTAssertEqual(count, 3)
    }

    func testDiscoveryAcceptsJSONOnlyAndInvalidationRejectsInFlightSupport() {
        var reply: ((Data?, URLResponse?, Error?) -> Void)?
        var requested: URLRequest?
        let cache = ServerCapabilitiesCache(transport: { request, completion in requested = request; reply = completion })
        var value: ServerCapabilities?
        cache.discover(baseUrl: "https://s.invalid") { value = $0 }
        cache.invalidate(baseUrl: "https://s.invalid")
        reply?(Data(Self.document.utf8), HTTPURLResponse(url: requested!.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]), nil)
        XCTAssertEqual(value, .unsupported)
        cache.discover(baseUrl: "https://s.invalid") { value = $0 }
        reply?(Data(Self.document.utf8), HTTPURLResponse(url: requested!.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]), nil)
        XCTAssertEqual(value, .unsupported)
    }

    func testRelayTestPublishRefusalInstallsOnlyPublishBudgetGate() {
        ContractURLProtocol.headers = ["Retry-After-Condition": "time", "Retry-After": "72000"]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = Store(inMemory: true)
        let topic = store.saveSubscription(baseUrl: "https://publish-refusal.invalid", topic: "topic")
        let baseUrl = topic.baseUrl!
        let cooldown = ServerCooldown(defaults: nil)
        let finished = expectation(description: "publish refused with a daily reset")
        ApiService().publish(subscription: topic, user: nil, message: "test", title: "test", session: session, cooldown: cooldown,
            completionHandler: { XCTFail("429 must fail the test publish") }, failureHandler: { error in
                XCTAssertEqual(error, .http(429))
                XCTAssertFalse(cooldown.claim(server: baseUrl, manual: true, kind: .publish))
                XCTAssertFalse(cooldown.claim(server: baseUrl, manual: false, kind: .clear))
                XCTAssertFalse(cooldown.claim(server: baseUrl, manual: false, kind: .action))
                XCTAssertTrue(cooldown.claim(server: baseUrl, manual: false, kind: .poll))
                finished.fulfill()
            })
        wait(for: [finished], timeout: 3)
    }

    func testClearReadsConditionFromHTTPResponse() {
        ContractURLProtocol.headers = ["Retry-After-Condition": "time", "Retry-After": "72000"]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "condition propagated")
        ApiService().action(ClearRequest(baseUrl: "https://s.invalid", topic: "t", sequence: "id", user: nil), session: session) {
            XCTAssertEqual($0, .conditionLimited(.time(72000)))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}

private final class ContractURLProtocol: URLProtocol {
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Opt-in integration gate. The private loopback harness supplies ephemeral server URLs through
/// the xctestrun environment; ordinary CI skips this test rather than relying on a public service.
final class NativeServerContractTests: XCTestCase {
    func testNativeRateResponsesDriveAppPolicies() throws {
        guard let encoded = ProcessInfo.processInfo.environment["NTFY_CONTRACT_NATIVE"],
              let data = encoded.data(using: .utf8),
              let cases = try? JSONDecoder().decode([NativeCase].self, from: data) else {
            throw XCTSkip("Run the native loopback contract harness to provide server cases")
        }
        for item in cases {
            let done = expectation(description: "native \(item.condition)")
            let store = Store(inMemory: true)
            let subscription = store.saveSubscription(baseUrl: item.url, topic: "audit-contract")
            let request = try XCTUnwrap(store.pollRequest(for: subscription))
            ApiService().poll(request) { _, error in
                let error = error as? PollHTTPError
                XCTAssertEqual(error?.status, 429)
                XCTAssertEqual(error?.retryCondition, item.condition.isEmpty ? nil : item.condition)
                let http = HTTPURLResponse(url: URL(string: item.url)!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After-Condition": item.condition, "Retry-After": error?.retryAfter ?? ""])!
                let delay = ActionExecutor.retryDelay(response: http, error: nil, attempt: 1)
                let cooldown = ServerCooldown(defaults: nil)
                cooldown.limit(server: item.url, retryAfter: error?.retryAfter, condition: error?.retryCondition)
                switch item.condition {
                case "time":
                    let seconds = Double(error?.retryAfter ?? "") ?? -1
                    XCTAssertGreaterThan(seconds, 3600, "native daily reset must exercise beyond the former cap")
                    XCTAssertNil(delay)
                    XCTAssertGreaterThan(cooldown.deadline(for: item.url).timeIntervalSinceNow, 3598)
                    XCTAssertLessThanOrEqual(cooldown.deadline(for: item.url).timeIntervalSinceNow, 3600)
                case "state-change", "request-change":
                    XCTAssertNil(error?.retryAfter)
                    XCTAssertNil(delay)
                    XCTAssertFalse(cooldown.claim(server: item.url, manual: false))
                default:
                    XCTAssertEqual(delay, 1)
                    XCTAssertGreaterThan(cooldown.deadline(for: item.url).timeIntervalSinceNow, 58)
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 15)
        }
    }
    private struct NativeCase: Decodable { let url: String; let condition: String }
}

final class NativeRoundTwoContractTests: XCTestCase {
    func testDailyClearRefusalStillAllowsRealPollThroughSubscriptionManager() throws {
        guard let value = ProcessInfo.processInfo.environment["NTFY_CONTRACT_DAILY"]?.data(using: .utf8) else {
            throw XCTSkip("Run round2/native_gate.py with the candidate loopback binary")
        }
        struct Daily: Decodable { let url: String; let id: String; let sequence: String }
        let fixture = try JSONDecoder().decode(Daily.self, from: value)
        let store = Store(inMemory: true)
        let topic = store.saveSubscription(baseUrl: fixture.url, topic: "audit-contract")
        let cooldown = ServerCooldown(defaults: nil)
        let manager = SubscriptionManager(store: store, polling: PollCoordinator(cooldown: cooldown))
        let clear = ClearRequest(baseUrl: fixture.url, topic: "audit-contract", sequence: fixture.sequence, user: nil, messageId: fixture.id)
        let finished = expectation(description: "42908 clear followed by admissible real GET")
        ClearPacer(cooldown: cooldown).send([clear], via: { request, done in ApiService().action(request, completion: done) }) { _, success in
            XCTAssertFalse(success)
            XCTAssertFalse(cooldown.claim(server: fixture.url, manual: false, kind: .clearThrough))
            manager.pollWithOutcome(topic) { result in
                XCTAssertTrue(result.attempted)
                XCTAssertTrue(result.succeeded)
                XCTAssertTrue(result.newMessages.contains { $0.id == fixture.id })
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 15)
    }

    func testStockUsesOneDiscoveryAcrossRelaunchAndPacedIndividualClears() throws {
        guard let value = ProcessInfo.processInfo.environment["NTFY_CONTRACT_STOCK"]?.data(using: .utf8) else {
            throw XCTSkip("Run round2/native_gate.py with unmodified stock v2.31.1")
        }
        struct Stock: Decodable { let url: String; let messages: [Message] }
        let fixture = try JSONDecoder().decode(Stock.self, from: value)
        let suite = "native-stock-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = ServerCooldown(defaults: nil)
        var discoveries = 0
        let cache = ServerCapabilitiesCache(cooldown: cooldown, allowInsecureLoopback: true, defaults: defaults, transport: { request, done in
            discoveries += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            ServerExtensionTransport.shared.send(request, completion: done)
        })
        let known = fixture.messages.map { ClearRequest(baseUrl: fixture.url, topic: "audit-stock", sequence: $0.sequence, user: nil, messageId: $0.id) }
        let boundary = try XCTUnwrap(known.last)
        let intent = ClearThroughIntent(boundary: boundary, candidates: [boundary], known: known)
        let coordinator = ClearThroughCoordinator(cooldown: cooldown, discover: { cache.discover(baseUrl: $0, user: $1, completion: $2) })
        let finished = expectation(description: "stock fallback individual clears")
        let pacer = ClearPacer(cooldown: cooldown)
        var remaining = known.count
        var starts: [Date] = []
        coordinator.send(intent) { result in
            guard case .fallback = result else { XCTFail("stock must retain individual clears"); finished.fulfill(); return }
            pacer.send(known, via: { request, done in
                starts.append(Date())
                ApiService().action(request, completion: done)
            }) { _, success in
                XCTAssertTrue(success)
                remaining -= 1
                if remaining == 0 { finished.fulfill() }
            }
        }
        wait(for: [finished], timeout: 20)
        XCTAssertEqual(starts.count, 2)
        if starts.count == 2 { XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.9) }
        let relaunched = ServerCapabilitiesCache(cooldown: cooldown, allowInsecureLoopback: true, defaults: defaults,
            transport: { _, _ in XCTFail("stock negative must survive relaunch for a day") })
        relaunched.discover(baseUrl: fixture.url) { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(discoveries, 1)
    }
}

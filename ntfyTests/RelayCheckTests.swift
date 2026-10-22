import XCTest
import CryptoKit
import SwiftUI
import UIKit
@testable import ntfy

final class RelayCheckTests: XCTestCase {
    private var reads: [URLRequest] = []
    private var replies: [(Int, String, [String: String])] = []
    private var pending: [() -> Void] = []
    private var delays: [TimeInterval] = []
    private var publishes = 0
    private let stamp: Int64 = 1792330000123

    private func json(_ stamp: Int64? = nil) -> String {
        "{\"relayed\":\(stamp == nil ? "false" : "true"),\"relayed_at\":\(stamp.map(String.init) ?? "null"),\"window_seconds\":120}"
    }
    private func make(supported: Bool = true) -> RelayCheck {
        RelayCheck(cooldown: nil, discover: { $0(supported) }, read: { request, completion in
            self.reads.append(request)
            let reply = self.replies.removeFirst()
            completion(Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0,
                httpVersion: "HTTP/1.1", headerFields: reply.2), nil)
        }, schedule: { delay, action in self.delays.append(delay); self.pending.append(action) })
    }
    private func drain() {
        let tick = expectation(description: "main queue callbacks")
        DispatchQueue.main.async { tick.fulfill() }
        wait(for: [tick], timeout: 2)
    }
    private func prepare(_ check: RelayCheck) {
        check.prepare(baseUrl: "https://private.example/ntfy", topic: "topic")
        drain()
    }
    private func approve(_ check: RelayCheck, error: String? = nil) {
        check.approve { done in self.publishes += 1; done(error) }
        drain()
        if delays.last == 0.002, !pending.isEmpty { advance() }
    }
    private func advance() { pending.removeFirst()(); drain() }

    func testDiscoveryDoesNotSendTestWithoutConsent() {
        let check = make(); prepare(check)
        XCTAssertEqual(check.state, .consent)
        XCTAssertTrue(reads.isEmpty); XCTAssertEqual(publishes, 0)
    }
    func testUnsupportedDoesNotPublishOrReadAndGivesManualGuidance() {
        let check = make(supported: false); prepare(check); approve(check)
        XCTAssertEqual(check.state, .unsupported)
        XCTAssertTrue(reads.isEmpty); XCTAssertEqual(publishes, 0)
        XCTAssertTrue(check.state.message!.contains("upstream-base-url"))
    }
    func testPlainHTTPRejectedBeforeDiscovery() {
        var discovered = false
        let check = RelayCheck(cooldown: nil, discover: { _ in discovered = true })
        check.prepare(baseUrl: "http://private.example", topic: "topic")
        XCTAssertFalse(discovered)
        XCTAssertEqual(check.state.message, String(localized: "An automatic relay check requires HTTPS for both your topic server and the relay. No test message was sent."))
    }
    func testInsecureRelayAndEmbeddedCredentialsAreRejected() {
        XCTAssertFalse(RelayCheck.isSecureBase("https://user:pass@example.com"))
        XCTAssertFalse(RelayCheck.isSecureBase("https://example.com?secret=yes"))
        XCTAssertFalse(RelayCheck.isSecureBase("http://example.com"))
        XCTAssertTrue(RelayCheck.isSecureBase("https://Example.com:8443/path/"))
    }
    func testHashPreservesExactConfiguredSpelling() {
        let base = "https://EXAMPLE.com:8443/ntfy/"
        let expected = SHA256.hash(data: Data((base + "/topic").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(RelayCheck.topicHash(baseUrl: base, topic: "topic"), expected)
        XCTAssertNotEqual(expected, RelayCheck.topicHash(baseUrl: "https://example.com:8443/ntfy", topic: "topic"))
    }
    func testPublishWaitsForMonotonicMillisecondBoundaryWithoutComparingDeviceClock() {
        replies = [(200,json(stamp),[:])]
        let check = make(); prepare(check)
        check.approve { done in self.publishes += 1; done(nil) }
        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(delays, [0.002])
        advance()
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(delays, [0.002, 1])
    }
    func testNewerTimestampStopsAfterFirstPostPublishRead() {
        replies = [(200,json(stamp),[:]), (200,json(stamp + 1),[:])]
        let check = make(); prepare(check); approve(check); advance()
        XCTAssertEqual(check.state, .received(stamp + 1))
        XCTAssertEqual(reads.count, 2); XCTAssertEqual(publishes, 1); XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(delays, [0.002, 1])
    }
    func testUnchangedBaselineDoesNotProveTestWasForwarded() {
        replies = Array(repeating: (200,json(stamp),[:]), count: 5)
        let check = make(); prepare(check); approve(check)
        for _ in 0..<4 { advance() }
        XCTAssertEqual(check.state, .notObserved)
        XCTAssertEqual(reads.count, 5); XCTAssertEqual(publishes, 1)
        XCTAssertEqual(delays, [0.002, 1, 2, 3, 4])
    }
    func testOlderTimestampAfterRestartDoesNotCountAsNewWake() {
        replies = [(200,json(stamp),[:])] + Array(repeating: (200,json(stamp - 1),[:]), count: 4)
        let check = make(); prepare(check); approve(check)
        for _ in 0..<4 { advance() }
        XCTAssertEqual(check.state, .notObserved)
    }
    func testNoBaselineThenRecentWakeIsObserved() {
        replies = [(200,json(),[:]), (200,json(stamp),[:])]
        let check = make(); prepare(check); approve(check); advance()
        XCTAssertEqual(check.state, .received(stamp))
    }
    func testDiagnosticBodyContainsOnlyHashAndNoCredentialsOrTopicURL() throws {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check)
        let request = try XCTUnwrap(reads.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfyme/relay-check")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Array(json.keys), ["hash"])
        XCTAssertEqual(json["hash"]?.count, 64)
        XCTAssertLessThanOrEqual(body.count, 128)
    }
    func testBaselineFailureDoesNotSendVisibleMessage() {
        replies = [(503,"",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(publishes, 0); XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(check.state.message!.contains("HTTP 503"))
    }
    func testRateLimitStateChangeStopsWithoutRetry() {
        replies = [(429,"",["Retry-After-Condition":"state-change"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains(String(localized: "Wait for the relevant server state to change before trying again.")))
        XCTAssertEqual(reads.count, 1); XCTAssertTrue(pending.isEmpty); XCTAssertEqual(publishes, 0)
    }
    func testRateLimitRequestChangeStopsWithoutRetry() {
        replies = [(429,"",["Retry-After-Condition":"request-change"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains(String(localized: "The server requires a different request before it can accept this check."))); XCTAssertTrue(pending.isEmpty)
    }
    func testTimedRateLimitRetainsDailyDelayInsteadOf3600Cap() {
        replies = [(429,"",["Retry-After-Condition":"time","Retry-After":"86400"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains(String(format: NSLocalizedString("Wait at least %lld seconds before trying again.", comment: ""), locale: DeliveryHealthCopy.retryIntervalLocale(), 86400))); XCTAssertTrue(pending.isEmpty)
        prepare(check)
        XCTAssertTrue(check.state.message!.contains(String(format: NSLocalizedString("Wait at least %lld seconds before trying again.", comment: ""), locale: DeliveryHealthCopy.retryIntervalLocale(), 86400)))
        XCTAssertEqual(reads.count, 1)
    }
    func testTimedCooldownSurvivesANewRelayViewAndSkipsAllHTTP() {
        let cooldown = ServerCooldown(defaults: nil)
        let first = RelayCheck(cooldown: cooldown, discover: { $0(true) }, read: { request, done in
            done(Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After-Condition": "time", "Retry-After": "72000"]), nil)
        })
        prepare(first)
        first.approve { _ in XCTFail("Rate-limited baseline must not publish") }
        var discoveryCalls = 0
        var httpCalls = 0
        let second = RelayCheck(cooldown: cooldown, discover: { completion in
            discoveryCalls += 1; completion(true)
        }, read: { _, _ in httpCalls += 1 })
        prepare(second)
        second.approve { _ in XCTFail("New view must retain the shared cooldown") }
        XCTAssertEqual(discoveryCalls, 0)
        XCTAssertEqual(httpCalls, 0)
        XCTAssertEqual(second.state.message, String(localized: "The relay is pausing requests after a rate limit. Wait for the requested delay or the relevant server or request change before trying again."))
    }
    func testUnsupportedEndpointStopsReads() {
        replies = [(404,"",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(check.state, .unsupported); XCTAssertEqual(publishes, 0)
    }
    func testMalformedSnapshotDoesNotPublish() {
        replies = [(200,"{\"relayed\":false,\"relayed_at\":123,\"window_seconds\":120}",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(publishes, 0); XCTAssertEqual(check.state.message, String(localized: "The relay did not return a valid check result (HTTP \(200)). This does not establish whether forwarding works."))
    }
    func testPublishFailureStopsReads() {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check, error: "HTTP 403")
        XCTAssertEqual(reads.count, 1); XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(check.state.message, String(localized: "The test message could not be confirmed: \("HTTP 403") No relay result is available."))
    }
    func testCancellationPreventsScheduledRead() {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check); check.cancel(); advance()
        XCTAssertEqual(check.state, .cancelled); XCTAssertEqual(reads.count, 1)
    }
    func testCancellationIgnoresLateDiscovery() {
        var callback: ((Bool) -> Void)?
        let check = RelayCheck(cooldown: nil, discover: { callback = $0 })
        check.prepare(baseUrl: "https://private.example", topic: "topic")
        check.cancel(); callback?(true); drain()
        XCTAssertEqual(check.state, .cancelled)
    }
    func testReceivedCopyDoesNotClaimPhoneDelivery() {
        let message = RelayCheck.State.received(stamp).message!
        let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(stamp) / 1000), dateStyle: .none, timeStyle: .medium)
        XCTAssertEqual(message, String(localized: "ntfy-me.com received a wake-up for this topic at \(time), and FCM accepted it. This does not prove your phone received it or that this test caused the wake-up."))
    }
    func testNoObservationCopyDoesNotAssertWrongConfigurationOrTwoMinuteTest() {
        let message = RelayCheck.State.notObserved.message!
        XCTAssertEqual(message, String(localized: "No newer forwarded wake-up was observed during this check (about 10 seconds). Check upstream-base-url: https://ntfy-me.com, the canonical base-url, outbound HTTPS, and the relay's status. Network or FCM trouble, delays, or evicted history can give the same result."))
        XCTAssertFalse(message.contains("in 2 minutes"))
    }

    func testWakeupCheckOnlyOffersSecureSelfHostedServers() {
        for base in ["https://ntfy-me.com", "https://NTFY-ME.com/path", "https://ntfy.sh", "https://NTFY.SH:443", "https://ntfy.sh.", "https://ntfy-me.com.", "http://private.example", "https://user:pass@private.example", "https://private.example?x=1", "not a URL"] {
            XCTAssertFalse(NotificationStatusView.offersWakeupCheck(baseUrl: base), base)
        }
        for base in ["https://private.example/ntfy", "https://192.168.1.2:8443", "https://localhost/ntfy"] {
            XCTAssertTrue(NotificationStatusView.offersWakeupCheck(baseUrl: base), base)
        }
    }

    func testCapabilityDiscoveryIsPublicAndDoesNotSendTopicCredentials() {
        let cache = ServerCapabilitiesCache(cooldown: ServerCooldown(defaults: nil), transport: { request, done in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.allHTTPHeaderFields?.count, 1)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            done(Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil), nil)
        })
        cache.discover(baseUrl: "https://private.example", user: BasicUser(username: "private-user", password: "secret")) {
            XCTAssertEqual($0, .unsupported)
        }
    }

    func testDiscoverySkipsEveryActiveBudgetWithoutSpendingManualRefreshProbe() {
        for kind: ServerCooldown.Kind in [.poll, .clear, .clearThrough, .relay, .discovery] {
            let cooldown = ServerCooldown(defaults: nil)
            let base = "https://limited.example"
            cooldown.limit(server: base, retryAfter: "600", kind: kind)
            let cache = ServerCapabilitiesCache(cooldown: cooldown, transport: { _, _ in
                XCTFail("Discovery must not spend a request while any rate-limit gate is active")
            })
            cache.discover(baseUrl: base) { XCTAssertEqual($0, .unsupported) }
            XCTAssertTrue(cooldown.claim(server: base, manual: true), "Discovery must preserve the user's refresh probe")
        }
    }

    func testDiscoveryGateIsNotCachedAsUnsupportedAfterGateExpires() {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var uptime: TimeInterval = 0
        let cooldown = ServerCooldown(defaults: nil, now: { date }, uptime: { uptime })
        let base = "https://limited.example"
        cooldown.limit(server: base, retryAfter: "60", kind: .clear)
        var calls = 0
        let cache = ServerCapabilitiesCache(cooldown: cooldown, now: { uptime }, transport: { request, done in
            calls += 1
            let json = "{\"version\":1,\"relay_check\":1,\"relay_window_seconds\":120}"
            done(Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]), nil)
        })
        cache.discover(baseUrl: base) { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(calls, 0)
        date += 60; uptime += 60
        cache.discover(baseUrl: base) { XCTAssertTrue($0.relayCheck) }
        XCTAssertEqual(calls, 1)
    }

    func testAuthoritativeNegativeDiscoveryPersistsOneDayAcrossRelaunch() throws {
        let suite = "RelayCheckTests.capabilities.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock: TimeInterval = 1_700_000_000
        var calls = 0
        func cache() -> ServerCapabilitiesCache {
            ServerCapabilitiesCache(cooldown: ServerCooldown(defaults: nil), now: { clock }, defaults: defaults,
                wallTime: { clock }, transport: { request, done in
                    calls += 1
                    done(Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil), nil)
                })
        }
        cache().discover(baseUrl: "https://stock.example") { XCTAssertEqual($0, .unsupported) }
        clock += 86399
        cache().discover(baseUrl: "https://stock.example") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(calls, 1)
        clock += 1
        cache().discover(baseUrl: "https://stock.example") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(calls, 2)
    }

    func testTransientDiscoveryFailuresAreRetriedInsteadOfCachingServerFact() {
        for status in [0, 401, 429, 503] {
            var calls = 0
            var clock: TimeInterval = 0
            var date = Date(timeIntervalSince1970: 1_700_000_000)
            let cooldown = ServerCooldown(defaults: nil, now: { date }, uptime: { clock })
            let cache = ServerCapabilitiesCache(cooldown: cooldown, now: { clock }, transport: { request, done in
                calls += 1
                if status == 0 { done(nil, nil, URLError(.notConnectedToInternet)); return }
                done(Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Retry-After": "1"]), nil)
            })
            cache.discover(baseUrl: "https://transient.example") { XCTAssertEqual($0, .unsupported) }
            clock += 1; date += 1
            cache.discover(baseUrl: "https://transient.example") { XCTAssertEqual($0, .unsupported) }
            XCTAssertEqual(calls, 2, "HTTP \(status) is not an authoritative unsupported result")
        }
    }

    /// Opt-in native UIKit/SwiftUI rendering evidence. These are presentation fixtures, separate
    /// from the native-server integration, and never claim a live delivery outcome.
    func testCaptureRelayResultStatesOnSimulator() throws {
        guard ProcessInfo.processInfo.environment["RELAY_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Opt in with RELAY_SCREENSHOTS=1 for native visual evidence")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("relay-screenshots")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, RelayCheck.State)] = [
            ("idle", .idle), ("discovering", .discovering), ("consent", .consent),
            ("checking", .checking), ("unsupported", .unsupported), ("cancelled", .cancelled),
            ("received", .received(stamp)), ("not-observed", .notObserved),
            ("network-error", .failed("The relay could not be reached. This check cannot tell whether wake-ups are forwarding. Try again when the connection is available.")),
            ("rate-limited", .failed("The relay rate limited this check. Wait at least 86400 seconds before trying again. No automatic retry will be sent."))
        ]
        defer { window.isHidden = true; previous?.makeKey() }
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for (name, state) in states {
            for variant in ["light", "dark", "largest-text"] {
                let root = NavigationView {
                    RelayCheckContentView(topicName: "Private alerts", baseUrl: "https://self-host.example/ntfy",
                        state: state, prepare: {}, approve: {}, cancel: {})
                }.navigationViewStyle(StackNavigationViewStyle())
                    .environment(\.colorScheme, variant == "dark" ? .dark : .light)
                    .environment(\.sizeCategory, variant == "largest-text" ? .accessibilityExtraExtraExtraLarge : .large)
                let host = UIHostingController(rootView: root)
                window.rootViewController = host
                window.overrideUserInterfaceStyle = variant == "dark" ? .dark : .light
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                let scroll = scrollViews(host.view).first
                // Form estimates off-screen cell heights. Recompute after each scroll so
                // the largest-text result and setup paragraphs are captured all the way down.
                var offset = -(scroll?.adjustedContentInset.top ?? 0)
                for page in 0..<20 {
                    scroll?.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    host.view.layoutIfNeeded()
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.6))
                    try data.write(to: directory.appendingPathComponent("\(name)-\(variant)-\(page).jpg"))
                    guard variant == "largest-text", let scroll else { break }
                    let bottom = max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    if scroll.contentOffset.y >= bottom - 1 { break }
                    offset = min(bottom, scroll.contentOffset.y + max(100, scroll.bounds.height * 0.65))
                    XCTAssertLessThan(page, 19, "Visual capture must reach the actual form bottom")
                }
            }
        }
        print("Relay visual evidence: \(directory.path)")
    }


}

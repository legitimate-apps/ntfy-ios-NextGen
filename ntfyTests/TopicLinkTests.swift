import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import ntfy

final class TopicLinkTests: XCTestCase {
    private func link(_ path: String) -> TopicLink? {
        TopicLink(url: URL(string: "https://ntfy-me.com" + path)!)
    }

    func testValidTopicAlphabetAndLength() {
        for topic in ["a", "_", "-", "A-Z_a-z_0123456789", String(repeating: "a", count: 64)] {
            XCTAssertEqual(link("/" + topic)?.topic, topic)
        }
    }

    func testRejectsInvalidTopicsAndMultipleSegments() {
        for path in ["", "/", "//", "/a/b", "//a", "/a//", "/a.json", "/a,b", "/a+b", "/a b",
                     "/é", "/a%0A", "/a%00", "/%2E", "/%2E%2E", "/a%2Fb", "/" + String(repeating: "a", count: 65)] {
            XCTAssertNil(link(path), path)
        }
    }

    func testTrailingSlashQueryAndFragmentDoNotChangeTopic() {
        XCTAssertEqual(link("/Alerts-42"), link("/Alerts-42/"))
        XCTAssertEqual(link("/Alerts-42"), link("/Alerts-42/?topic=other&subscribe=true#different"))
    }

    func testTopicCaseIsPreserved() {
        XCTAssertEqual(link("/Alerts")?.topic, "Alerts")
        XCTAssertNotEqual(link("/Alerts"), link("/alerts"))
    }

    func testExactServerReservedList() {
        let reserved = ["docs", "static", "file", "app", "metrics", "account", "settings", "signup", "login", "v1"]
        XCTAssertEqual(TopicLink.reservedNames, Set(reserved))
        for name in reserved {
            XCTAssertNil(link("/" + name), name)
            XCTAssertNil(link("/" + name + "/?q=x#fragment"), name)
            XCTAssertNotNil(link("/" + name.uppercased()), name)
        }
        XCTAssertNotNil(link("/docs-alerts"))
    }

    func testDecodedPathsStillObeyTopicAndReservedRules() {
        XCTAssertEqual(link("/%41lerts")?.topic, "Alerts")
        XCTAssertNil(link("/%61pp"))
        XCTAssertNil(link("/alerts%252Fother"))
    }

    func testOnlyTheHTTPSOriginIsAccepted() {
        for url in ["http://ntfy-me.com/alerts", "https://ntfy.sh/alerts", "https://www.ntfy-me.com/alerts",
                    "https://ntfy-me.com.evil.test/alerts", "https://ntfy-me.com:8443/alerts",
                    "https://user@ntfy-me.com/alerts", "https://user:password@ntfy-me.com/alerts",
                    "ntfy://ntfy-me.com/alerts"] {
            XCTAssertNil(TopicLink(url: URL(string: url)!), url)
        }
        XCTAssertEqual(TopicLink(url: URL(string: "HTTPS://NTFY-ME.COM:443/Alerts")!), link("/Alerts"))
    }

    func testNewTopicRoutesToConfirmationWithExplicitServer() {
        let url = URL(string: "https://ntfy-me.com/alerts")!
        XCTAssertEqual(TopicLinkRoute.resolve(url, subscriptionURLs: []), .add(TopicLink(url: url)!))
        XCTAssertEqual(TopicLink.baseURL, "https://ntfy-me.com")
    }

    func testSubscribedTopicRoutesToTheStoredNavigationURL() {
        let stored = "https://NTFY-ME.COM:443/Alerts"
        XCTAssertEqual(TopicLinkRoute.resolve(URL(string: "https://ntfy-me.com/Alerts/?q=x#fragment")!,
                                              subscriptionURLs: [stored]), .open(stored))
    }

    func testSameNameOnAnotherServerAndDifferentCaseAreDifferentTopics() {
        let url = URL(string: "https://ntfy-me.com/Alerts")!
        XCTAssertEqual(TopicLinkRoute.resolve(url, subscriptionURLs: ["https://ntfy.sh/Alerts", "https://ntfy-me.com/alerts"]),
                       .add(TopicLink(url: url)!))
    }

    func testReservedInvalidAndOtherHostHaveNoRoutingDecision() {
        for url in ["https://ntfy-me.com/docs", "https://ntfy-me.com/a/b", "https://ntfy.sh/alerts"] {
            XCTAssertNil(TopicLinkRoute.resolve(URL(string: url)!, subscriptionURLs: [url]))
        }
    }
}

/// QR codes: what the app encodes, and how a decoded code is parsed and routed (upstream ntfy #756).
final class TopicQRCodeTests: XCTestCase {
    private func scanned(_ text: String) -> TopicLink? { TopicLink(scanned: text) }

    func testUniversalLinkCarriesItsServer() {
        XCTAssertEqual(TopicLink(url: URL(string: "https://NTFY-ME.COM:443/Alerts")!)?.server, "https://ntfy-me.com")
    }

    func testScannedNtfyMeTopicMatchesTheUniversalLink() {
        let link = scanned("https://ntfy-me.com/Alerts-42")
        XCTAssertEqual(link?.server, "https://ntfy-me.com")
        XCTAssertEqual(link?.topic, "Alerts-42")
        XCTAssertEqual(link, TopicLink(url: URL(string: "https://ntfy-me.com/Alerts-42")!))
    }

    func testSelfHostedServerWithPortAndPathPrefix() {
        let link = scanned("https://Push.Example.org:8443/ntfy/sub/home_alerts?x=1#frag")
        XCTAssertEqual(link?.server, "https://push.example.org:8443/ntfy/sub")
        XCTAssertEqual(link?.topic, "home_alerts")
        XCTAssertEqual(scanned("http://192.168.1.20:8080/garage/")?.server, "http://192.168.1.20:8080")
        XCTAssertEqual(scanned("http://[fd00::5]:2586/garage")?.server, "http://[fd00::5]:2586")
        // Default ports are dropped so the stored URL and the scanned one compare equal.
        XCTAssertEqual(scanned("https://ntfy.sh:443/a")?.server, "https://ntfy.sh")
        XCTAssertEqual(scanned("http://ntfy.home:80/a")?.server, "http://ntfy.home")
    }

    func testAndroidDeepLinkFormat() {
        XCTAssertEqual(scanned("ntfy://ntfy.sh/alerts"), scanned("https://ntfy.sh/alerts"))
        XCTAssertEqual(scanned("ntfy://ntfy.home:2586/alerts?secure=false&display=Garage"),
                       scanned("http://ntfy.home:2586/alerts"))
        XCTAssertNil(scanned("ntfy://ntfy.sh/prefix/alerts"))
    }

    func testAddressWithoutSchemeMeansHTTPS() {
        XCTAssertEqual(scanned("  ntfy.sh/alerts\n"), scanned("https://ntfy.sh/alerts"))
    }

    func testNonTopicAddressesAreRejected() {
        for text in ["https://ntfy.sh/", "https://ntfy.sh", "https://ntfy.sh/docs/publish/", "https://ntfy.sh/app",
                     "https://ntfy.sh/alerts.json", "https://example.com/a/b.html", "https://ntfy.sh/a%2Fb",
                     "https://ntfy.sh//alerts", "https://user:pw@ntfy.sh/alerts", "ftp://ntfy.sh/alerts",
                     "mailto:someone@example.com", "tel:+15551234567", "ntfy://ntfy.sh/v1",
                     "https://ntfy.sh/" + String(repeating: "a", count: 65)] {
            XCTAssertNil(scanned(text), text)
        }
    }

    func testGarbageIsRejected() {
        for text in ["", "   ", "alerts", "hello world", "WIFI:S:Home;T:WPA;P:secret;;",
                     "BEGIN:VCARD\nFN:Someone\nEND:VCARD", "🙂/🙂", "://", "https://"] {
            XCTAssertNil(scanned(text), text)
        }
    }

    func testScanOfANewTopicRoutesToTheAddSheetOnItsServer() {
        let route = TopicLinkRoute.resolve(scanned: "https://push.example.org:8443/ntfy/alerts",
                                           subscriptionURLs: ["https://ntfy-me.com/alerts", "https://push.example.org/ntfy/alerts"])
        XCTAssertEqual(route, .add(TopicLink(scanned: "https://push.example.org:8443/ntfy/alerts")!))
    }

    func testScanOfASubscribedTopicOpensTheStoredOne() {
        let stored = "https://Push.Example.org:443/ntfy/alerts"
        XCTAssertEqual(TopicLinkRoute.resolve(scanned: "ntfy://push.example.org/alerts", subscriptionURLs: [stored]),
                       .add(TopicLink(scanned: "https://push.example.org/alerts")!))
        XCTAssertEqual(TopicLinkRoute.resolve(scanned: "https://push.example.org/ntfy/alerts/", subscriptionURLs: [stored]),
                       .open(stored))
    }

    func testScanOfANonTopicHasNoRoute() {
        XCTAssertNil(TopicLinkRoute.resolve(scanned: "https://ntfy.sh/docs", subscriptionURLs: []))
        XCTAssertNil(TopicLinkRoute.resolve(scanned: "not a link", subscriptionURLs: []))
    }

    func testPayloadIsTheTopicURL() {
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "https://ntfy-me.com/", topic: "Alerts"), "https://ntfy-me.com/Alerts")
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "http://ntfy.home:2586/sub", topic: "a"), "http://ntfy.home:2586/sub/a")
    }

    func testPayloadRemovesAuthenticationAndURLMetadata() {
        for server in ["https://user:password@push.example:8443/prefix?token=secret#private",
                       "https://push.example:8443/prefix/?token=secret#private"] {
            XCTAssertEqual(TopicQRCode.payload(baseUrl: server, topic: "Alerts"),
                           "https://push.example:8443/prefix/Alerts")
        }
    }

    func testPayloadPreservesEncodedServerPrefix() {
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "https://push.example/root%2Fproxy?token=secret", topic: "Alerts-42"),
                       "https://push.example/root%2Fproxy/Alerts-42")
    }

    func testPayloadRefusesAddressesThatCannotRoundTripAsTopics() {
        for server in ["", "https://", "file:///private", "ftp://push.example", "https://push.example/docs",
                       "https://push.example//prefix", "https://push.example:99999"] {
            XCTAssertNil(TopicQRCode.payload(baseUrl: server, topic: "Alerts"), server)
        }
        for topic in ["", "docs", "a/b", "a?token=secret", String(repeating: "a", count: 65)] {
            XCTAssertNil(TopicQRCode.payload(baseUrl: "https://push.example", topic: topic))
        }
    }

    func testHTTPScanUsesHTTPSOnlyForTheAppsOwnHost() {
        for code in ["http://NTFY-ME.COM/Alerts", "http://ntfy-me.com:80/Alerts",
                     "ntfy://ntfy-me.com/Alerts?secure=false"] {
            XCTAssertEqual(scanned(code)?.server, "https://ntfy-me.com")
            XCTAssertEqual(TopicLinkRoute.resolve(scanned: code, subscriptionURLs: ["https://ntfy-me.com/Alerts"]),
                           .open("https://ntfy-me.com/Alerts"))
        }
        XCTAssertEqual(scanned("http://ntfy-me.com.evil.test/Alerts")?.server, "http://ntfy-me.com.evil.test")
        XCTAssertEqual(scanned("http://ntfy.home/Alerts")?.server, "http://ntfy.home")
    }

    func testGeneratedCodeDecodesBackToTheSameTopic() throws {
        for (baseUrl, topic, expectedServer) in [
            ("https://ntfy-me.com", "Alerts-42", "https://ntfy-me.com"),
            ("http://push.example.org:8443/ntfy", "home_alerts", "http://push.example.org:8443/ntfy"),
            ("https://user:password@push.example.org/prefix?token=secret#private", "alerts", "https://push.example.org/prefix")
        ] {
            let payload = try XCTUnwrap(TopicQRCode.payload(baseUrl: baseUrl, topic: topic))
            let image = try XCTUnwrap(TopicQRCode.image(for: payload))
            let ciImage = try XCTUnwrap(CIImage(image: image))
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let decoded = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(decoded, [payload])
            let link = try XCTUnwrap(TopicLink(scanned: decoded[0]))
            XCTAssertEqual(link.server, expectedServer)
            XCTAssertEqual(link.topic, topic)
        }
    }

    func testCodeIsLargeEnoughToReadAtArmsLength() throws {
        // 12 pixels per module; a short topic URL is a 25-module (version 2) code or larger.
        let image = try XCTUnwrap(TopicQRCode.image(for: "https://ntfy-me.com/alerts"))
        XCTAssertGreaterThanOrEqual(image.size.width, 25 * 12)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func testCameraStates() {
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: false, status: .authorized), .unavailable)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .authorized), .scanning)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .notDetermined), .needsPermission)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .denied), .denied)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .restricted), .denied)
    }
}

final class TopicQRScannerTextTests: XCTestCase {
    func testRejectedCodesNeverExposeTheirContents() {
        XCTAssertEqual(TopicQRScannerView.rejectionText("https://ntfy.sh/docs"),
                       "That code isn't an ntfy topic address.")
        for secret in ["https://user:password@example.org/topic", "http://example.org/docs?reset_token=abc#private",
                       "ntfy://example.org/docs?token=secret", "WIFI:S:Home;T:WPA;P:secret;;",
                       "BEGIN:VCARD\nFN:Someone\nEND:VCARD", "otpauth://totp/x?secret=ABC"] {
            XCTAssertEqual(TopicQRScannerView.rejectionText(secret), "That code isn't an ntfy topic address.", secret)
        }
    }
}

final class TopicQRCameraLifecycleTests: XCTestCase {
    func testReturningFromSettingsRefreshesDeniedAuthorization() {
        let center = NotificationCenter()
        var status = AVAuthorizationStatus.denied
        let camera = TopicQRAuthorization(hasCamera: { true }, status: { status }, center: center)
        camera.appear()
        XCTAssertEqual(camera.state, .denied)
        status = .authorized
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(camera.state, .scanning)
        status = .denied
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(camera.state, .denied)
    }

    func testBackgroundStopsAndForegroundRestartsOnlyVisibleAuthorizedCapture() {
        let center = NotificationCenter()
        let queue = DispatchQueue(label: "test.qr.capture")
        var authorized = true
        var events = [String]()
        let capture = TopicQRCaptureLifecycle(queue: queue, center: center, isActive: true,
            authorized: { authorized }, start: { events.append("start") }, stop: { events.append("stop") })
        capture.appear()
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "stop", "background capture must be explicitly stopped")
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        capture.disappear()
        queue.sync {}
        let dismissedEvents = events
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events, dismissedEvents, "a dismissed scanner must not restart")
        authorized = false
        capture.appear()
        queue.sync {}
        XCTAssertEqual(events.last, "stop", "revoked access must prevent a restart")
    }

    func testPermissionCompletionWhileInactiveCannotStartCapture() {
        let center = NotificationCenter()
        let queue = DispatchQueue(label: "test.qr.inactive")
        var events = [String]()
        let capture = TopicQRCaptureLifecycle(queue: queue, center: center, isActive: false,
            authorized: { true }, start: { events.append("start") }, stop: { events.append("stop") })
        capture.appear()
        queue.sync {}
        XCTAssertFalse(events.contains("start"))
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        capture.disappear()
        queue.sync {}
    }
}

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

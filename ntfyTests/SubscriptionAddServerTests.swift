import XCTest
@testable import ntfy

final class SubscriptionAddServerTests: XCTestCase {
    func testBlankAlternateUsesSettingsDefaultForBothToggleStates() {
        let store = Store(inMemory: true)
        store.saveDefaultBaseUrl(baseUrl: "https://configured.example/prefix/")
        for useAnother in [false, true] {
            for input in ["", "   ", "\n\t"] {
                XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: useAnother, input: input, defaultBaseUrl: store.getDefaultBaseUrl()), "https://configured.example/prefix")
            }
        }
    }

    func testUnsetSettingsUsesAppDefaultAndDetectsExistingTopic() {
        let store = Store(inMemory: true)
        let expected = normalizeBaseUrl(Config.appBaseUrl)
        let existing = store.saveSubscription(baseUrl: expected, topic: "already-subscribed")
        let selected = SubscriptionAddServer.selectedBaseUrl(useAnother: true, input: "", defaultBaseUrl: store.getDefaultBaseUrl())
        XCTAssertEqual(selected, expected)
        XCTAssertEqual(store.getSubscription(baseUrl: selected, topic: "already-subscribed"), existing)
    }

    func testNonblankAlternateAndDisabledToggleKeepTheirMeaning() {
        XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: true, input: "  https://other.example/prefix/  ", defaultBaseUrl: "https://default.example"), "https://other.example/prefix")
        XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: false, input: "https://other.example", defaultBaseUrl: "https://default.example/"), "https://default.example")
        XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: true, input: "invalid server", defaultBaseUrl: "https://default.example"), "invalid server")
        for invalid in ["/", " /// "] {
            XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: true, input: invalid, defaultBaseUrl: "https://default.example"), "")
        }
    }

    func testPlaceholderNamesTheActualConfiguredFallback() {
        XCTAssertEqual(SubscriptionAddServer.placeholder(defaultBaseUrl: "https://configured.example/prefix/"), "Blank uses https://configured.example/prefix")
        XCTAssertEqual(SubscriptionAddServer.placeholder(defaultBaseUrl: Config.appBaseUrl), "Blank uses \(normalizeBaseUrl(Config.appBaseUrl))")
    }
}

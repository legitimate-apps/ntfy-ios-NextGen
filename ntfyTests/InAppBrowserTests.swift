import XCTest
@testable import ntfy

final class InAppBrowserTests: XCTestCase {
    func testWebLinksUseBrowserOnlyWhenEnabled() throws {
        for value in ["http://example.com", "https://example.com/path?q=1#fragment", "HTTPS://example.com"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(InAppBrowser.shouldOpen(url, enabled: true), value)
            XCTAssertFalse(InAppBrowser.shouldOpen(url, enabled: false), value)
        }
    }
    func testOtherSchemesAlwaysUseSystem() throws {
        for value in ["mailto:a@example.com", "tel:123", "ntfy://topic", "file:///test", "ftp://example.com", "javascript:alert(1)", "/relative", "https:relative"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(InAppBrowser.shouldOpen(url, enabled: true), value)
        }
    }
    func testNewPreferenceDefaultsToSystemAndPersistsOptIn() throws {
        let name = "InAppBrowserTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertFalse(InAppBrowser.shouldOpen(url, enabled: defaults.bool(forKey: InAppBrowser.preferenceKey)))
        defaults.set(true, forKey: InAppBrowser.preferenceKey)
        XCTAssertTrue(InAppBrowser.shouldOpen(url, enabled: defaults.bool(forKey: InAppBrowser.preferenceKey)))
        defaults.set(false, forKey: InAppBrowser.preferenceKey)
        XCTAssertFalse(InAppBrowser.shouldOpen(url, enabled: defaults.bool(forKey: InAppBrowser.preferenceKey)))
    }
}

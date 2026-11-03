import XCTest
import SwiftUI
import UIKit
import Vision
@testable import ntfy

final class SubscriptionAddServerTests: XCTestCase {
    /// ntfy#1294: the signed-in add sheet must expose account discovery without adding anything.
    /// This uses only pre-feature public entry points, so it runs unchanged on the base commit.
    @MainActor
    func testSignedInAddSheetOffersSavedAccountTopicsWithoutSubscribing() throws {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        XCTAssertTrue(store.saveUser(baseUrl: store.getDefaultBaseUrl(), credential: .accessToken("tk_test")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = UIHostingController(rootView:
            SubscriptionAddView(isShowing: .constant(true))
                .environmentObject(store).environmentObject(AppDelegate())
                .environment(\.sizeCategory, .large).environment(\.colorScheme, .light))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "account-topics-render"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Topics saved in account"), "Signed-in user must be able to discover existing account topics. Rendered: \(text)")
        XCTAssertEqual(store.getSubscriptions()?.count, 0, "Opening the add sheet must never silently subscribe")
    }

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

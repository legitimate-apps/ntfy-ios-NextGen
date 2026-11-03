import XCTest
import SwiftUI
import UIKit
import Vision
@testable import ntfy

final class AccountTopicsTests: XCTestCase {
    private let server = "https://account.invalid/ntfy"
    private let user = ServerCredential.accessToken("tk_test")

    private func fetch(_ body: String, status: Int = 200, user: ServerCredential? = .accessToken("tk_test")) async -> [AccountTopic] {
        AccountTopicsProtocol.body = Data(body.utf8)
        AccountTopicsProtocol.status = status
        AccountTopicsProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountTopicsProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await withCheckedContinuation { continuation in
            ApiService(credentialStore: InMemoryCredentialStore()).accountTopics(baseURL: server + "/", user: user, session: session) {
                continuation.resume(returning: $0)
            }
        }
    }

    // ntfy#1294: real account JSON keys, nullable names, normalized server path, deduplication,
    // invalid topics and foreign servers. Only the user's own endpoint receives credentials.
    func testAccountWireContractKeepsNamesAndOnlyThisServersValidTopics() async {
        let items = await fetch(#"{"username":"tester","role":"user","subscriptions":[{"base_url":"https://account.invalid/ntfy/","topic":"alerts","display_name":"Home alerts"},{"base_url":"https://account.invalid/ntfy","topic":"plain","display_name":null},{"base_url":"https://account.invalid/ntfy","topic":"alerts"},{"base_url":"https://other.invalid","topic":"foreign"},{"base_url":"https://account.invalid/ntfy","topic":"bad/topic"},null]}"#)
        XCTAssertEqual(items.map(\.topic), ["alerts", "plain"])
        XCTAssertEqual(items.map(\.title), ["Home alerts", "plain"])
        XCTAssertEqual(AccountTopicsProtocol.requests.count, 1)
        XCTAssertEqual(AccountTopicsProtocol.requests.first?.url?.absoluteString, server + "/v1/account")
        XCTAssertEqual(AccountTopicsProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tk_test")
    }

    func testUnsupportedAnonymousAndMalformedAccountsQuietlyHaveNoTopics() async {
        for (body, status) in [("{}", 404), ("{}", 401), ("{}", 403), ("<html>proxy</html>", 200),
                               (#"{"username":"*","role":"anonymous","subscriptions":[]}"#, 200),
                               (#"{"username":"tester"}"#, 200), (#"{"username":"tester","subscriptions":null}"#, 200)] {
            let items = await fetch(body, status: status)
            XCTAssertTrue(items.isEmpty, "status \(status), body \(body)")
        }
        let anonymousRole = await fetch(#"{"username":"tester","role":"anonymous","subscriptions":[{"base_url":"https://account.invalid/ntfy","topic":"hidden"}]}"#)
        XCTAssertTrue(anonymousRole.isEmpty)
        let anonymousWithTopics = await fetch(#"{"username":"*","subscriptions":[{"base_url":"https://account.invalid/ntfy","topic":"hidden"}]}"#)
        XCTAssertTrue(anonymousWithTopics.isEmpty)
    }

    func testNoSavedLoginDoesNotRequestAccountAndBasicLoginUsesExistingHeaders() async {
        let items = await fetch("{}", user: nil)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(AccountTopicsProtocol.requests.isEmpty)
        _ = await fetch(#"{"username":"tester"}"#, user: .basic(username: "tester", password: "pass"))
        XCTAssertEqual(AccountTopicsProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       ServerCredential.basic(username: "tester", password: "pass").toHeader())
    }

    @MainActor
    private func fixture(_ topics: [AccountTopic], authorize: @escaping (String) async -> Bool = { _ in true }) -> (Store, AccountTopicsModel, ImportRecorder) {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let recorder = ImportRecorder()
        let model = AccountTopicsModel(baseURL: server, user: user, store: store, loadTopics: { topics }, authorize: authorize) { item in
            recorder.topics.append(item.topic)
            store.saveSubscription(baseUrl: self.server, topic: item.topic)
        }
        return (store, model, recorder)
    }

    private func topic(_ name: String, displayName: String? = nil, baseURL: String? = nil) -> AccountTopic {
        AccountTopic(baseURL: baseURL ?? server, topic: name, displayName: displayName)
    }

    @MainActor
    func testLoadingIsOptInAndSkipsDuplicatesExistingAndForeignTopics() async {
        let existing = topic("existing", displayName: "Remote name")
        let new = topic("new", displayName: "New name")
        let (store, model, recorder) = fixture([existing, new, new, topic("foreign", baseURL: "https://other.invalid"), topic("bad/name")])
        let old = store.saveSubscription(baseUrl: server, topic: "existing")
        store.updateSubscription(subscription: old, displayName: "Local name")
        await model.load()
        XCTAssertEqual(model.topics, [new])
        XCTAssertTrue(model.selected.isEmpty)
        let noSelection = await model.importSelected()
        XCTAssertNil(noSelection)
        XCTAssertTrue(recorder.topics.isEmpty)
        XCTAssertNil(store.getSubscription(baseUrl: server, topic: "new"))
        XCTAssertEqual(old.customDisplayName, "Local name")
    }

    @MainActor
    func testOnlySelectedTopicsSubscribeAndNamesUseExistingStoreRules() async {
        let first = topic("first", displayName: "  Server name \n")
        let (store, model, recorder) = fixture([first, topic("unselected")])
        await model.load()
        model.selected = [first.id, "https://other.invalid/injected"]
        let imported = await model.importSelected()
        XCTAssertEqual(imported, first.id)
        XCTAssertEqual(recorder.topics, ["first"])
        let subscription = store.getSubscription(baseUrl: server, topic: "first")
        XCTAssertEqual(subscription?.customDisplayName, "Server name")
        XCTAssertNotNil(subscription?.subscribedAt)
        XCTAssertNil(store.getSubscription(baseUrl: server, topic: "unselected"))
        XCTAssertEqual(model.topics.map(\.topic), ["unselected"])
    }

    @MainActor
    func testAuthFailureKeepsFailedSelectionAndRetryDoesNotRepeatSuccessfulImports() async {
        let first = topic("first"), denied = topic("denied")
        var allowed = false
        let (store, model, recorder) = fixture([first, denied], authorize: { $0 != "denied" || allowed })
        await model.load()
        model.selected = [first.id, denied.id]
        let partial = await model.importSelected()
        XCTAssertNil(partial)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(recorder.topics, ["first"])
        XCTAssertEqual(model.importedURL, first.id, "Back after partial success must still offer the normal permission flow")
        XCTAssertNil(store.getSubscription(baseUrl: server, topic: "denied"))
        XCTAssertEqual(model.selected, [denied.id])
        allowed = true
        let retry = await model.importSelected()
        XCTAssertEqual(retry, first.id)
        XCTAssertEqual(model.importedURL, first.id)
        XCTAssertEqual(model.importedURLs, [first.id, denied.id])
        XCTAssertEqual(recorder.topics, ["first", "denied"])
        XCTAssertFalse(model.failed)
        XCTAssertTrue(model.topics.isEmpty)
    }

    @MainActor
    func testConcurrentSubscribeDuringAuthIsNotDuplicatedOrRenamed() async {
        let item = topic("race", displayName: "Account name")
        let store = Store(inMemory: true)
        var imports = 0
        let model = AccountTopicsModel(baseURL: server, user: user, store: store, loadTopics: { [item] }, authorize: { _ in
            let subscription = store.saveSubscription(baseUrl: self.server, topic: item.topic)
            store.updateSubscription(subscription: subscription, displayName: "Local name")
            return true
        }, subscribe: { _ in imports += 1 })
        await model.load()
        model.selected = [item.id]
        _ = await model.importSelected()
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(store.getSubscriptions()?.count, 1)
        XCTAssertEqual(store.getSubscription(baseUrl: server, topic: item.topic)?.customDisplayName, "Local name")
    }

    @MainActor
    func testLeavingPickerDuringAuthCancelsRemainingSubscriptions() async {
        let first = topic("first"), second = topic("second")
        var release: CheckedContinuation<Bool, Never>?
        let entered = expectation(description: "first auth started")
        var requests = 0
        let (_, model, recorder) = fixture([first, second], authorize: { _ in
            requests += 1
            entered.fulfill()
            return await withCheckedContinuation { release = $0 }
        })
        await model.load()
        model.selected = [first.id, second.id]
        let task = Task { await model.importSelected() }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        release?.resume(returning: true)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(recorder.topics.isEmpty)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testRefreshKeepsSelectionOnlyForTopicsStillInTheAccount() async {
        let first = topic("first"), second = topic("second"), new = topic("new")
        var saved = [first, second]
        let model = AccountTopicsModel(baseURL: server, user: user, store: Store(inMemory: true), loadTopics: { saved })
        await model.load()
        model.selected = [first.id]
        saved = [first, second, new]
        await model.load()
        XCTAssertEqual(model.selected, [first.id], "Refreshing must preserve the user's explicit choices")
        XCTAssertEqual(model.topics, saved)
        saved = [second, new]
        await model.load()
        XCTAssertTrue(model.selected.isEmpty, "Removed account topics must not remain importable")
    }

    func testPrimerUsesBatchCopyAndKeepsTheSingleTopicAddress() {
        let url = server + "/first"
        let single = SubscriptionPermissionCopy.message(baseUrl: server, topicURL: url, topicCount: 1)
        XCTAssertTrue(single.contains("account.invalid/ntfy/first"), single)
        let batch = SubscriptionPermissionCopy.message(baseUrl: server, topicURL: url, topicCount: 2)
        XCTAssertTrue(batch.contains("topics you added"), "A batch must describe all imported topics: \(batch)")
        XCTAssertFalse(batch.contains("account.invalid/ntfy/first"), batch)
    }

    @MainActor
    func testFailedPersistenceLeavesTopicSelectedForRetry() async {
        let item = topic("not-saved")
        let model = AccountTopicsModel(baseURL: server, user: user, store: Store(inMemory: true), loadTopics: { [item] }, authorize: { _ in true }, subscribe: { _ in })
        await model.load()
        model.selected = [item.id]
        let result = await model.importSelected()
        XCTAssertNil(result)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(model.selected, [item.id])
        XCTAssertEqual(model.topics, [item])
    }
    @MainActor
    func testImportThroughSubscriptionManagerKeepsPushQueueAndPollInvariants() async {
        let item = topic("manager", displayName: "Manager name")
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let subscriber = AccountTopicsSubscriber()
        let suite = "account-topics-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let reconciler = FcmSubscriptionReconciler(store: store, subscriber: subscriber, defaults: defaults)
        var polled: [String] = []
        let manager = SubscriptionManager(store: store, reconciler: reconciler, polling: PollCoordinator(cooldown: ServerCooldown(defaults: nil)), fetch: { request, completion in
            polled.append(request.topicUrl)
            completion([], nil)
        })
        let model = AccountTopicsModel(baseURL: server, user: user, store: store, loadTopics: { [item] }, authorize: { _ in true }, subscribe: {
            manager.subscribe(baseUrl: self.server, topic: $0.topic)
        })
        await model.load()
        model.selected = [item.id]
        _ = await model.importSelected()
        let drained = expectation(description: "normal subscribe callbacks")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(polled, [item.id])
        XCTAssertTrue(subscriber.topics.contains(firebaseTopic(baseUrl: server, topic: item.topic)))
        let subscription = store.getSubscription(baseUrl: server, topic: item.topic)
        XCTAssertEqual(subscription?.customDisplayName, "Manager name")
        XCTAssertEqual(subscription?.fcmSubscribed, true)
        XCTAssertNotNil(subscription?.subscribedAt)
    }

    @MainActor
    func testPickerRendersAccountNamesAndTopicIdentifiers() async throws {
        let text = try await renderedPickerText([topic("home-alerts", displayName: "Home alerts"), topic("build-results", displayName: "Build results"), topic("backups")])
        XCTAssertTrue(text.contains("Home alerts"), text)
        XCTAssertTrue(text.contains("home-alerts"), text)
        XCTAssertTrue(text.contains("backups"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Topics saved in account"), text)
    }

    @MainActor
    func testEmptyAccountExplainsWebAppSourceWithoutChooseInstruction() async throws {
        let text = try await renderedPickerText([])
        XCTAssertTrue(text.localizedCaseInsensitiveContains("ntfy web app"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Choose topics"), text)
    }

    @MainActor
    private func renderedPickerText(_ items: [AccountTopic]) async throws -> String {
        let (_, model, _) = fixture(items)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        let root = NavigationView {
            AccountTopicsView(model: model, onImported: { _ in })
        }.navigationViewStyle(StackNavigationViewStyle())
            .environment(\.sizeCategory, .large).environment(\.colorScheme, .light)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 800_000_000)
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
        return text
    }

}

@MainActor
private final class ImportRecorder { var topics: [String] = [] }

private final class AccountTopicsProtocol: URLProtocol {
    static var body = Data()
    static var status = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "account.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AccountTopicsSubscriber: FcmTopicSubscriber {
    let hasApnsToken = true
    var topics: [String] = []
    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
        topics.append(topic)
        completion(nil)
    }
    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
}

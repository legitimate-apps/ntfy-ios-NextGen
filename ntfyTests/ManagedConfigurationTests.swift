import XCTest
import UIKit
@testable import ntfy

final class ManagedConfigurationTests: XCTestCase {
    private final class Subscriber: FcmTopicSubscriber {
        var hasApnsToken = true
        var calls: [String] = []
        func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
            calls.append(topic)
            completion(nil)
        }
        func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
    }
    private var store: Store!
    private var defaults: UserDefaults!
    private var suite: String!
    private var subscriber: Subscriber!
    private var manager: SubscriptionManager!
    private var subject: ManagedConfiguration!
    private var fetches = 0
    private let server = "https://mdm.example.test"

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        suite = "ManagedConfigurationTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(Config.appBaseUrl, forKey: FcmSubscriptionReconciler.defaultsKeyBindingsAppBaseUrl)
        defaults.set(true, forKey: "pollTopicFcmSubscribed")
        subscriber = Subscriber()
        manager = SubscriptionManager(store: store,
            reconciler: FcmSubscriptionReconciler(store: store, subscriber: subscriber, defaults: defaults),
            polling: PollCoordinator(defaults: defaults))
        manager.fetch = { [weak self] _, completion in
            self?.fetches += 1
            completion([], nil)
        }
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
    }
    override func tearDown() {
        drain()
        subject = nil
        defaults.removePersistentDomain(forName: suite)
        store = nil
        super.tearDown()
    }
    private func drain() {
        let done = expectation(description: "main queue reconciliation")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }
    private func topic(_ name: String, displayName: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["server": server, "topic": name]
        value["displayName"] = displayName
        return value
    }
    private func apply(_ value: Any?) {
        if let value { defaults.set(value, forKey: ManagedConfiguration.configurationKey) }
        else { defaults.removeObject(forKey: ManagedConfiguration.configurationKey) }
        subject.refresh()
        drain()
    }
    private var errors: [String] { defaults.dictionary(forKey: ManagedConfiguration.feedbackKey)?["errors"] as? [String] ?? [] }

    func testValidConfigurationUsesRealSubscribePathAndSetsDefault() throws {
        apply(["defaultServer": "https://MDM.example.test:443/", "topics": [topic("alerts", displayName: "Operations")]])
        XCTAssertEqual(store.getDefaultBaseUrl(), server)
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        XCTAssertEqual(row.customDisplayName, "Operations")
        XCTAssertTrue(row.fcmSubscribed)
        XCTAssertEqual(subscriber.calls, [firebaseTopic(baseUrl: server, topic: "alerts")])
        XCTAssertEqual(fetches, 1, "Must use SubscriptionManager, including its initial poll")
        XCTAssertEqual(defaults.dictionary(forKey: ManagedConfiguration.feedbackKey)?["applied"] as? Int, 2)
        XCTAssertTrue(errors.isEmpty)
    }

    func testReapplyAndNewReaderDoNotDuplicateOrRepeatFCMOrPoll() throws {
        let configuration: [String: Any] = ["defaultServer": server, "topics": [topic("alerts")]]
        apply(configuration)
        let id = try XCTUnwrap(store.getSubscriptions()?.first?.objectID)
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
        apply(configuration)
        XCTAssertEqual(store.getSubscriptions()?.map(\.objectID), [id])
        XCTAssertEqual(subscriber.calls.count, 1)
        XCTAssertEqual(fetches, 1)
    }

    func testRemovedTopicsKeepHistoryAndBecomePersonalWithoutTouchingPersonalTopic() throws {
        let personal = store.saveSubscription(baseUrl: server, topic: "personal")
        store.updateSubscription(subscription: personal, displayName: "My topic")
        apply(["topics": [topic("alerts", displayName: "IT"), topic("personal", displayName: "Admin")]])
        let managed = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        let message = Message(id: "mdmhistory", time: 1, event: "message", topic: "alerts", message: "Retain this message")
        _ = store.save(notificationsFromMessages: [message], withSubscription: managed)
        apply([:])
        XCTAssertEqual(managed.notifications?.count, 1)
        XCTAssertEqual(store.getSubscriptions()?.count, 2)
        XCTAssertEqual(personal.customDisplayName, "My topic")
        store.updateSubscription(subscription: managed, displayName: "Mine now")
        apply(["topics": [topic("alerts", displayName: "Admin again")]])
        XCTAssertEqual(managed.customDisplayName, "Mine now", "A released topic is personal")
    }

    func testManagedNamesUpdateAndUnsubscribeIsRestoredOnRefresh() throws {
        apply(["topics": [topic("alerts", displayName: "Old")]])
        apply(["topics": [topic("alerts", displayName: "New")]])
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        XCTAssertEqual(row.customDisplayName, "New")
        apply(["topics": [topic("alerts")]])
        XCTAssertNil(row.customDisplayName)
        manager.unsubscribe(row)
        drain()
        XCTAssertNil(store.getSubscription(baseUrl: server, topic: "alerts"))
        subject.refresh()
        drain()
        XCTAssertNotNil(store.getSubscription(baseUrl: server, topic: "alerts"))
        XCTAssertEqual(fetches, 2)
    }

    func testUnnamedManagedTopicsPreserveUserNamesOnActivationAndReaderRestart() throws {
        let entries = [topic("omitted"), topic("empty", displayName: "  ")]
        apply(["topics": entries])
        let omitted = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "omitted"))
        let empty = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "empty"))
        store.updateSubscription(subscription: omitted, displayName: "My omitted topic")
        store.updateSubscription(subscription: empty, displayName: "My empty topic")
        subject.start() // The same refresh path used on launch and activation.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        drain()
        XCTAssertEqual(omitted.customDisplayName, "My omitted topic")
        XCTAssertEqual(empty.customDisplayName, "My empty topic")
        apply(["topics": entries + [topic("additional")]])
        XCTAssertEqual(omitted.customDisplayName, "My omitted topic")
        XCTAssertEqual(empty.customDisplayName, "My empty topic")
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
        subject.refresh()
        XCTAssertEqual(omitted.customDisplayName, "My omitted topic")
        XCTAssertEqual(empty.customDisplayName, "My empty topic")
    }

    func testAdminNameChangesApplyButUnchangedNamePreservesLaterUserRename() throws {
        apply(["topics": [topic("alerts", displayName: "First admin name")]])
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        XCTAssertEqual(row.customDisplayName, "First admin name")
        store.updateSubscription(subscription: row, displayName: "My name")
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
        subject.refresh()
        XCTAssertEqual(row.customDisplayName, "My name")
        apply(["topics": [topic("alerts", displayName: "Second admin name")]])
        XCTAssertEqual(row.customDisplayName, "Second admin name")
        store.updateSubscription(subscription: row, displayName: "My later name")
        subject.refresh()
        XCTAssertEqual(row.customDisplayName, "My later name")
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(subscriber.calls.count, 1)
    }

    func testRemovingAdminNameClearsItsValueButPreservesLaterUserName() throws {
        apply(["topics": [topic("owned", displayName: "Admin"), topic("renamed", displayName: "Admin")]])
        let owned = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "owned"))
        let renamed = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "renamed"))
        store.updateSubscription(subscription: renamed, displayName: "My replacement")
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
        apply(["topics": [topic("owned"), topic("renamed", displayName: "")]])
        XCTAssertNil(owned.customDisplayName)
        XCTAssertEqual(renamed.customDisplayName, "My replacement")
        store.updateSubscription(subscription: owned, displayName: "My name after removal")
        subject = ManagedConfiguration(manager: manager, defaults: defaults)
        subject.refresh()
        XCTAssertEqual(owned.customDisplayName, "My name after removal")
        XCTAssertEqual(renamed.customDisplayName, "My replacement")
    }

    func testAdminCanFirstSetANameAfterUserRenamesAnUnnamedTopic() throws {
        apply(["topics": [topic("alerts")]])
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        store.updateSubscription(subscription: row, displayName: "My name")
        apply(["topics": [topic("alerts", displayName: "Admin supplied name")]])
        XCTAssertEqual(row.customDisplayName, "Admin supplied name")
    }

    func testUserRecreatedTopicIsNotClaimedByOldOwnership() throws {
        apply(["topics": [topic("alerts", displayName: "IT")]])
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "alerts"))
        manager.unsubscribe(row)
        drain()
        let personal = store.saveSubscription(baseUrl: server, topic: "alerts")
        store.updateSubscription(subscription: personal, displayName: "My replacement")
        subject.refresh()
        XCTAssertEqual(personal.customDisplayName, "My replacement")
    }

    func testBadEntriesDoNotBlockValidOnesAndFeedbackContainsNoValues() {
        let invalid: [Any] = [17, ["server": server, "topic": 2], topic("bad/name"), topic(String(repeating: "a", count: 65)),
            ["server": "https://user:SECRET@example.test", "topic": "bad"], ["server": "file:///tmp", "topic": "bad"],
            ["server": "https:///", "topic": "bad"], ["server": server, "topic": "bad", "displayName": false],
            ["server": server, "topic": "bad", "password": "SECRET"], topic("good"), topic("good")]
        apply(["defaultServer": false, "password": "SECRET", "topics": invalid])
        XCTAssertEqual(store.getSubscriptions()?.map(\.topic), ["good"])
        XCTAssertEqual(errors.count, 12)
        XCTAssertFalse(errors.joined().contains("SECRET"))
        XCTAssertEqual((store.credentialStore as? InMemoryCredentialStore)?.typedWriteAttempts, 0)
        XCTAssertEqual((store.credentialStore as? InMemoryCredentialStore)?.passwordWrites.count, 0)
        XCTAssertNil(store.getUser(baseUrl: server))
    }

    func testMalformedMissingAndEmptyConfigurationsAreSafeAndDefaultRestores() {
        store.saveDefaultBaseUrl(baseUrl: "https://personal.example.test")
        apply(["defaultServer": server, "topics": [topic("alerts")]])
        apply("wrong root type")
        XCTAssertEqual(store.getDefaultBaseUrl(), server)
        XCTAssertFalse(errors.isEmpty)
        apply(["defaultServer": server, "topics": "wrong array type"])
        XCTAssertEqual(store.getSubscriptions()?.count, 1)
        XCTAssertFalse(errors.isEmpty)
        apply(nil)
        XCTAssertEqual(store.getDefaultBaseUrl(), "https://personal.example.test")
        XCTAssertEqual(store.getSubscriptions()?.count, 1)
        apply([:])
        XCTAssertTrue(errors.isEmpty)
    }

    func testRemovingDefaultDoesNotOverwriteLaterUserChoice() {
        apply(["defaultServer": server])
        store.saveDefaultBaseUrl(baseUrl: "https://chosen.example.test")
        apply([:])
        XCTAssertEqual(store.getDefaultBaseUrl(), "https://chosen.example.test")
    }

    func testStartAppliesAndObservesLiveChangesAndActivation() throws {
        defaults.set(["topics": [topic("launch")]], forKey: ManagedConfiguration.configurationKey)
        subject.start()
        subject.start() // Starting twice must not register duplicate observers.
        drain()
        XCTAssertNotNil(store.getSubscription(baseUrl: server, topic: "launch"))
        defaults.set(["topics": [topic("live")]], forKey: ManagedConfiguration.configurationKey)
        drain()
        XCTAssertNotNil(store.getSubscription(baseUrl: server, topic: "live"))
        let row = try XCTUnwrap(store.getSubscription(baseUrl: server, topic: "live"))
        manager.unsubscribe(row)
        drain()
        defaults.set(true, forKey: "unrelatedSetting")
        drain()
        XCTAssertNil(store.getSubscription(baseUrl: server, topic: "live"), "Unrelated defaults must not reapply management")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        drain()
        XCTAssertNotNil(store.getSubscription(baseUrl: server, topic: "live"))
    }

    func testServerValidationRejectsAmbiguousOrSecretBearingURLs() {
        for value in ["", "example.test", "ftp://example.test", "https://", "https://a b", "https://user@example.test", "https://a?token=SECRET", "https://a#fragment", "https://a:0", "https://a:65536", " https://a"] {
            XCTAssertNil(ManagedConfiguration.server(value), value)
        }
        XCTAssertNil(ManagedConfiguration.server(17))
        XCTAssertEqual(ManagedConfiguration.server("http://localhost:8080/ntfy/"), "http://localhost:8080/ntfy")
        XCTAssertEqual(ManagedConfiguration.server("https://[::1]:443/"), "https://[::1]")
    }
}

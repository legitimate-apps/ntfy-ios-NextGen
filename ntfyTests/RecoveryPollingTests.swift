import XCTest
@testable import ntfy

final class RecoveryPollingTests: XCTestCase {
    private var store: Store!
    private var manager: SubscriptionManager!
    private var subscriptions: [Subscription] = []
    private var fetched: [String] = []
    override func setUp() {
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore(), topicSecrets: InMemoryTopicSecretStore())
        manager = SubscriptionManager(store: store, polling: PollCoordinator(defaults: nil))
        manager.fetch = { request, done in self.fetched.append(URL(string: request.topicUrl)!.lastPathComponent); done([], nil) }
    }
    override func tearDown() {
        for subscription in subscriptions {
            DeliveryHealthMonitor.shared.received(key: key(subscription))
        }
    }
    private func key(_ sub: Subscription) -> String { sub.objectID.uriRepresentation().absoluteString }
    private func topic(_ name: String, failure: PollFailure?) -> Subscription {
        let sub = store.saveSubscription(baseUrl: "https://recovery.example", topic: name)
        subscriptions.append(sub)
        DeliveryHealthMonitor.shared.record(key: key(sub), failure: failure)
        return sub
    }
    private func recover(_ subs: [Subscription]) {
        let done = expectation(description: "recovery finished")
        manager.pollAll(subs, manual: false, recovering: true) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
    func testOnlyUnreachableTopicsAreRetriedAndSuccessClearsHealth() {
        let failed = topic("unreachable", failure: .unreachable)
        let others = [topic("healthy", failure: nil), topic("auth", failure: .unauthorized),
                      topic("limited", failure: .rateLimited), topic("other", failure: .other)]
        recover([failed] + others)
        XCTAssertEqual(fetched, ["unreachable"])
        XCTAssertNil(DeliveryHealthMonitor.shared.topics[key(failed)])
        XCTAssertEqual(DeliveryHealthMonitor.shared.topics[key(others[1])]?.failure, .unauthorized)
    }
    func testRecoveryBypassesUnreachableBackoffButOrdinaryForegroundKeepsIt() {
        let sub = topic("offline", failure: nil)
        let request = store.pollRequest(for: sub)!
        XCTAssertTrue(manager.polling.begin(request, manual: false) { _ in })
        manager.polling.finish(request, outcome: PollOutcome(succeeded: false, newMessages: [], failure: .unreachable), retryAfter: nil)
        let skipped = expectation(description: "ordinary catch-up skipped")
        manager.pollAll([sub], manual: false) { skipped.fulfill() }
        wait(for: [skipped], timeout: 5); XCTAssertTrue(fetched.isEmpty)
        recover([sub]); XCTAssertEqual(fetched, ["offline"])
        XCTAssertNil(DeliveryHealthMonitor.shared.topics[key(sub)])
    }
    func testRecoveryRespectsServerCooldownAndDoesNotTakeManualProbe() {
        let sub = topic("limited-offline", failure: .unreachable)
        manager.polling.cooldown.limit(server: sub.baseUrl!, retryAfter: "120")
        recover([sub]); XCTAssertTrue(fetched.isEmpty)
        XCTAssertNotNil(manager.polling.cooldown.claimAttempt(server: sub.baseUrl!, manual: true))
    }
    func testRecoveryJoinsExistingTopicRequestWithoutAnotherFetch() {
        let sub = topic("overlap", failure: .unreachable)
        var reply: (([Message]?, Error?) -> Void)?
        manager.fetch = { request, done in self.fetched.append(URL(string: request.topicUrl)!.lastPathComponent); reply = done }
        let first = expectation(description: "first fetch")
        manager.pollWithOutcome(sub) { _ in first.fulfill() }
        let joined = expectation(description: "joined fetch")
        manager.pollAll([sub], manual: false, recovering: true) { joined.fulfill() }
        XCTAssertEqual(fetched, ["overlap"])
        reply?([], nil); wait(for: [first, joined], timeout: 5)
        XCTAssertNil(DeliveryHealthMonitor.shared.topics[key(sub)])
    }
}

import XCTest
@testable import ntfy

final class TopicServerAddressTests: XCTestCase {
    func testDefaultKeepsAddressesAndToggleHidesUniqueNames() {
        XCTAssertTrue(TopicServerAddressPolicy.showsAddress(name: "alerts", ambiguousNames: []))
        XCTAssertFalse(TopicServerAddressPolicy.showsAddress(name: "alerts", showAddresses: false, ambiguousNames: []))
    }

    func testSameNamesOnDifferentServersRemainIdentifiable() {
        let store = Store(inMemory: true)
        let first = store.saveSubscription(baseUrl: "https://one.example", topic: "alerts")
        let second = store.saveSubscription(baseUrl: "https://two.example", topic: "alerts")
        let unique = store.saveSubscription(baseUrl: "https://two.example", topic: "weather")
        let names = TopicServerAddressPolicy.ambiguousNames(in: [first, second, unique])
        XCTAssertEqual(names, ["alerts"])
        XCTAssertTrue(TopicServerAddressPolicy.showsAddress(name: first.shortDisplayName(), showAddresses: false, ambiguousNames: names))
        XCTAssertTrue(TopicServerAddressPolicy.showsAddress(name: second.shortDisplayName(), showAddresses: false, ambiguousNames: names))
        XCTAssertFalse(TopicServerAddressPolicy.showsAddress(name: unique.shortDisplayName(), showAddresses: false, ambiguousNames: names))
    }

    func testCustomNamesAndCaseCollisionsUseTheRenderedName() {
        let store = Store(inMemory: true)
        let first = store.saveSubscription(baseUrl: "https://one.example", topic: "first")
        let second = store.saveSubscription(baseUrl: "https://two.example", topic: "second")
        first.customDisplayName = " Work "; second.customDisplayName = "work"
        var names = TopicServerAddressPolicy.ambiguousNames(in: [first, second])
        XCTAssertEqual(names, ["work"])
        XCTAssertTrue(TopicServerAddressPolicy.showsAddress(name: first.shortDisplayName(), showAddresses: false, ambiguousNames: names))
        second.customDisplayName = "Personal"
        names = TopicServerAddressPolicy.ambiguousNames(in: [first, second])
        XCTAssertTrue(names.isEmpty)
        XCTAssertFalse(TopicServerAddressPolicy.showsAddress(name: first.shortDisplayName(), showAddresses: false, ambiguousNames: names))
    }

    func testCustomNamesOnSameServerAreAlsoAmbiguousUntilRemoved() {
        let store = Store(inMemory: true)
        let first = store.saveSubscription(baseUrl: "https://one.example", topic: "first")
        let second = store.saveSubscription(baseUrl: "https://one.example", topic: "second")
        first.customDisplayName = "Work"; second.customDisplayName = "Work"
        XCTAssertEqual(TopicServerAddressPolicy.ambiguousNames(in: [first, second]), ["work"])
        XCTAssertTrue(TopicServerAddressPolicy.ambiguousNames(in: [first]).isEmpty)
    }
}

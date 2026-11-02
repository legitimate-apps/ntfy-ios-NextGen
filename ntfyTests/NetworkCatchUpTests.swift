import XCTest
@testable import ntfy

final class NetworkCatchUpTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var jobs: [(TimeInterval, () -> Void)] = []
    private var unreachable = true
    private var polls: [Bool] = []
    private var completions: [() -> Void] = []
    private lazy var policy = NetworkCatchUp(hasUnreachable: { self.unreachable }, poll: { recovery, done in
        self.polls.append(recovery); self.completions.append(done)
    }, now: { self.clock }, schedule: { self.jobs.append((self.clock + $0, $1)) })
    private func advance(_ seconds: TimeInterval) {
        let end = clock + seconds
        while let index = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: index); clock = job.0; job.1()
        }
        clock = end
    }
    private func completeFirst() {
        guard !completions.isEmpty else { XCTFail("Expected an in-flight batch"); return }
        completions.removeFirst()()
    }
    private func activate(path: String? = "wifi") {
        policy.pathChanged(path); policy.activate()
        XCTAssertEqual(polls, [false]); completeFirst()
    }
    func testUnavailableToUsableDebouncesAndDeduplicatesUpdates() {
        activate(path: nil)
        policy.pathChanged("wifi"); policy.pathChanged("wifi")
        advance(0.49); XCTAssertEqual(polls, [false])
        advance(0.011); XCTAssertEqual(polls, [false, true])
        policy.pathChanged("wifi"); advance(60)
        XCTAssertEqual(polls, [false, true])
    }
    func testInterfaceChangeCountsButInitialAndDuplicateSnapshotsDoNot() {
        policy.activate(); completeFirst()
        policy.pathChanged("cellular"); advance(1); XCTAssertEqual(polls, [false])
        policy.pathChanged("wifi"); advance(0.5); XCTAssertEqual(polls, [false, true])
    }
    func testHealthyPathChangesDoNotPollAndHealthIsRecheckedAtExecution() {
        activate(); unreachable = false
        policy.pathChanged("cellular"); advance(1); XCTAssertEqual(polls, [false])
        unreachable = true; policy.pathChanged("wifi")
        unreachable = false; advance(1); XCTAssertEqual(polls, [false])
    }
    func testRecoveryDuringForegroundPollWaitsForLateFailure() {
        policy.pathChanged(nil); policy.activate()
        policy.pathChanged("wifi"); advance(10); XCTAssertEqual(polls, [false])
        completeFirst(); advance(0.5)
        XCTAssertEqual(polls, [false, true])
    }
    func testRecoveryInFlightAndFlappingHaveOneTrailingRetryAfterThirtySeconds() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.5)
        XCTAssertEqual(polls, [false, true])
        policy.pathChanged(nil); policy.pathChanged("cellular"); advance(1)
        XCTAssertEqual(polls, [false, true])
        completeFirst(); advance(28.9)
        XCTAssertEqual(polls, [false, true])
        advance(0.11); XCTAssertEqual(polls, [false, true, true])
    }
    func testLatestPathMustStayUsableForDebounce() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.3)
        policy.pathChanged(nil); advance(1); XCTAssertEqual(polls, [false])
        policy.pathChanged("wifi"); advance(0.3); policy.pathChanged("cellular")
        advance(0.3); XCTAssertEqual(polls, [false])
        advance(0.21); XCTAssertEqual(polls, [false, true])
    }
    func testBackgroundCancelsPendingRecoveryAndResumeDoesOrdinaryCatchUp() {
        activate(path: nil); policy.pathChanged("wifi"); policy.deactivate()
        advance(1); policy.pathChanged("cellular"); advance(60)
        XCTAssertEqual(polls, [false])
        policy.activate(); XCTAssertEqual(polls, [false, false])
        completeFirst(); advance(60); XCTAssertEqual(polls, [false, false])
    }
    func testPersistentFailureDoesNotBecomeARetryTimer() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.5)
        XCTAssertEqual(polls, [false, true]); completeFirst()
        advance(600); XCTAssertEqual(polls, [false, true])
    }
    func testBackgroundWhileFetchCompletesDropsPendingPath() {
        policy.pathChanged(nil); policy.activate(); policy.pathChanged("wifi")
        policy.deactivate(); completeFirst(); advance(60)
        XCTAssertEqual(polls, [false])
    }
    func testForegroundTransitionsNeverOverlapAndDoNotLoseResume() {
        policy.pathChanged("wifi"); policy.activate(); policy.deactivate(); policy.activate()
        XCTAssertEqual(polls, [false]); completeFirst()
        XCTAssertEqual(polls, [false, false])
    }
}

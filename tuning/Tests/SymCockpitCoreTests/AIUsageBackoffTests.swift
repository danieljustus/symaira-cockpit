import XCTest
@testable import SymCockpitCore

final class AIUsageBackoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFailuresDoubleUpToTheCapAndASuccessClears() {
        var backoff = AIUsageBackoff()
        let interval: TimeInterval = 300
        var now = t0
        for expected in [300.0, 600, 1200, 2400, 3600, 3600] {
            backoff.record(provider: "p", error: "HTTP 500", now: now, interval: interval)
            XCTAssertTrue(backoff.isWaiting("p", now: now.addingTimeInterval(expected - 1), manual: false))
            XCTAssertFalse(backoff.isWaiting("p", now: now.addingTimeInterval(expected), manual: false), "\(expected)")
            XCTAssertFalse(backoff.isWaiting("p", now: now, manual: true), "a manual refresh skips the failure backoff")
            now = now.addingTimeInterval(expected)
        }
        backoff.record(provider: "p", error: nil, now: now, interval: interval)
        XCTAssertFalse(backoff.isWaiting("p", now: now, manual: false))
    }

    func testAProviderRequestedWaitHoldsEvenForAManualRefresh() {
        var backoff = AIUsageBackoff()
        backoff.record(provider: "claude", error: #"AI usage provider "claude" is rate limited; retry in 1800s"#,
                       now: t0, interval: 60)
        XCTAssertTrue(backoff.isWaiting("claude", now: t0.addingTimeInterval(1799), manual: true))
        XCTAssertFalse(backoff.isWaiting("claude", now: t0.addingTimeInterval(1800), manual: true))
        XCTAssertFalse(backoff.isWaiting("other", now: t0, manual: false))
    }

    func testTheWaitIsReadFromSymbrainsMessage() {
        XCTAssertEqual(AIUsageBackoff.providerWait(in: #"provider "x" is rate limited; retry in 30s"#), 30)
        XCTAssertNil(AIUsageBackoff.providerWait(in: #"provider "x" is rate limited"#))
        XCTAssertNil(AIUsageBackoff.providerWait(in: "HTTP 500"))
    }
}

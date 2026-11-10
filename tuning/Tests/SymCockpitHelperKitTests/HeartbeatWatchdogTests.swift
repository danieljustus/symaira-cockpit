import XCTest
@testable import SymCockpitHelperKit

/// Settable clock shared with the watchdog under test.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 1_000
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
}

final class HeartbeatWatchdogTests: XCTestCase {
    func testConstantsMatchTheDocumentedContract() {
        XCTAssertEqual(FanHelperConstants.heartbeatInterval, 2)
        XCTAssertEqual(FanHelperConstants.heartbeatTimeout, 7)
        XCTAssertGreaterThan(FanHelperConstants.heartbeatTimeout, FanHelperConstants.heartbeatInterval * 3)
    }

    func testNotExpiredWithinTheTimeout() {
        let clock = FakeClock()
        let watchdog = HeartbeatWatchdog(timeout: 7, clock: { clock.read() })
        clock.advance(6.9)
        XCTAssertFalse(watchdog.isExpired)
    }

    func testExpiryIsStrictlyGreaterThanTheTimeout() {
        let clock = FakeClock()
        let watchdog = HeartbeatWatchdog(timeout: 7, clock: { clock.read() })
        clock.advance(7)
        XCTAssertFalse(watchdog.isExpired, "exactly 7 s is still inside the limit")
        clock.advance(0.01)
        XCTAssertTrue(watchdog.isExpired)
    }

    func testBeatResetsTheTimer() {
        let clock = FakeClock()
        let watchdog = HeartbeatWatchdog(timeout: 7, clock: { clock.read() })
        clock.advance(6)
        watchdog.beat()
        clock.advance(6)
        XCTAssertFalse(watchdog.isExpired)
        XCTAssertEqual(watchdog.secondsSinceLastBeat, 6, accuracy: 0.0001)
    }
}

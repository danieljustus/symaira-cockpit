import XCTest
@testable import SymCockpitHelperKit

final class FanHelperIdleMonitorTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _governing = false
        private var _connected = false
        private var _date = Date(timeIntervalSince1970: 1_000_000)
        var governing: Bool { get { lock.lock(); defer { lock.unlock() }; return _governing } set { lock.lock(); _governing = newValue; lock.unlock() } }
        var connected: Bool { get { lock.lock(); defer { lock.unlock() }; return _connected } set { lock.lock(); _connected = newValue; lock.unlock() } }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _date }
        func advance(_ seconds: TimeInterval) { lock.lock(); _date += seconds; lock.unlock() }
    }

    private func monitor(_ state: State, grace: TimeInterval = 5) -> FanHelperIdleMonitor {
        FanHelperIdleMonitor(
            grace: grace,
            isGoverning: { state.governing },
            hasConnection: { state.connected },
            now: { state.now }
        )
    }

    // MARK: - Pure rule

    func testTheRuleExitsOnlyWhenIdleLongEnough() {
        typealias M = FanHelperIdleMonitor
        XCTAssertTrue(M.shouldExit(isGoverning: false, hasConnection: false, idleFor: 5, grace: 5))
        XCTAssertTrue(M.shouldExit(isGoverning: false, hasConnection: false, idleFor: 60, grace: 5))
        XCTAssertFalse(M.shouldExit(isGoverning: false, hasConnection: false, idleFor: 4.9, grace: 5))
        XCTAssertFalse(M.shouldExit(isGoverning: true, hasConnection: false, idleFor: 600, grace: 5), "never while governing")
        XCTAssertFalse(M.shouldExit(isGoverning: false, hasConnection: true, idleFor: 600, grace: 5), "never while connected")
        XCTAssertFalse(M.shouldExit(isGoverning: true, hasConnection: true, idleFor: 600, grace: 5))
    }

    // MARK: - Monitor

    func testAFreshHelperThatNobodyConnectsToExitsAfterTheGrace() {
        let state = State()
        let m = monitor(state)
        XCTAssertFalse(m.tick())
        state.advance(4)
        XCTAssertFalse(m.tick())
        state.advance(1)
        XCTAssertTrue(m.tick())
    }

    func testItNeverExitsWhileAClientIsConnected() {
        let state = State()
        state.connected = true
        let m = monitor(state)
        for _ in 0..<10 { state.advance(60); XCTAssertFalse(m.tick()) }
    }

    func testItNeverExitsWhileGoverningEvenWithoutAConnection() {
        // The connection dropped but the governor is still unwinding: the
        // fans are not restored yet.
        let state = State()
        state.governing = true
        let m = monitor(state)
        for _ in 0..<10 { state.advance(60); XCTAssertFalse(m.tick()) }
    }

    func testTheGraceRestartsAfterTheGovernorHasRestoredTheFans() {
        let state = State()
        state.connected = true
        state.governing = true
        let m = monitor(state)
        state.advance(100)
        XCTAssertFalse(m.tick())
        // Client gone; the governor is still restoring the fans.
        state.connected = false
        state.advance(10)
        XCTAssertFalse(m.tick())
        // Restored: the idle clock starts now, not at the disconnect.
        state.governing = false
        state.advance(1)
        XCTAssertFalse(m.tick())
        state.advance(4.9)
        XCTAssertFalse(m.tick())
        state.advance(0.2)
        XCTAssertTrue(m.tick())
    }

    func testANewConnectionWithinTheGraceCancelsTheExit() {
        let state = State()
        let m = monitor(state)
        state.advance(4)
        XCTAssertFalse(m.tick())
        state.connected = true
        state.advance(1)
        XCTAssertFalse(m.tick())
        state.connected = false
        state.advance(1)
        XCTAssertFalse(m.tick(), "the grace starts over after the last connection")
        state.advance(5)
        XCTAssertTrue(m.tick())
    }
}

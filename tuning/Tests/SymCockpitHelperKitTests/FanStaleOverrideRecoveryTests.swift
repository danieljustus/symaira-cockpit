import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

/// Issue #414: a helper that died mid-governing leaves the fans forced; the
/// next helper (or the next Standard) must hand them back to the firmware.
final class FanStaleOverrideRecoveryTests: XCTestCase {
    private struct Rejected: Error {}

    func testNothingForcedSkipsTheProbeAndTheWrite() {
        var probed = false, restored = false
        let outcome = FanStaleOverrideRecovery.run(
            hasOverride: { false },
            legacyGovernorRunning: { probed = true; return false },
            restore: { restored = true }
        )
        XCTAssertEqual(outcome, .nothingForced)
        XCTAssertFalse(probed)
        XCTAssertFalse(restored)
    }

    func testARunningStandaloneGovernorKeepsItsFans() {
        var restored = false
        let outcome = FanStaleOverrideRecovery.run(
            hasOverride: { true }, legacyGovernorRunning: { true }, restore: { restored = true }
        )
        XCTAssertEqual(outcome, .legacyGovernorRunning)
        XCTAssertFalse(restored)
    }

    func testAStaleOverrideIsRestoredAndAFailureIsReported() {
        XCTAssertEqual(
            FanStaleOverrideRecovery.run(hasOverride: { true }, legacyGovernorRunning: { false }, restore: {}),
            .restored
        )
        guard case .failed = FanStaleOverrideRecovery.run(
            hasOverride: { true }, legacyGovernorRunning: { false }, restore: { throw Rejected() }
        ) else { return XCTFail("a rejected restore must not report success") }
    }
}

final class FanHelperEngineStaleRecoveryTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeEngine(counter: Counter, runner: FakeGovernorRunner) -> FanHelperEngine {
        FanHelperEngine(
            watchdog: HeartbeatWatchdog(timeout: 7, clock: { FakeClock().read() }),
            sleepSlice: 0.005,
            staleRecovery: { counter.increment() },
            runner: runner.runner()
        )
    }

    func testLaunchRecoveryRunsWhenIdle() {
        let counter = Counter()
        let engine = makeEngine(counter: counter, runner: FakeGovernorRunner())
        engine.recoverStaleOverride()
        XCTAssertEqual(counter.count, 1)
    }

    /// Standard on a fresh helper (no run to stop) still recovers the fans.
    func testStandardWithoutARunRecovers() {
        let counter = Counter()
        let engine = makeEngine(counter: counter, runner: FakeGovernorRunner())
        engine.stop(reason: .requested)
        engine.start(profile: .system)
        XCTAssertEqual(counter.count, 2)
    }

    /// While a run exists its governor owns (and restores) the fans; the
    /// recovery must never race it, and watchdog/connection stops never trigger it.
    func testNoRecoveryWhileARunIsActiveOrForNonStandardStops() {
        let counter = Counter()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(counter: counter, runner: fake)
        engine.start(profile: .comfort)
        engine.recoverStaleOverride()
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(counter.count, 0, "an orderly stop restores through the governor itself")

        engine.stop(reason: .heartbeatTimeout)
        engine.connectionInvalidated()
        XCTAssertEqual(counter.count, 0)

        engine.stop(reason: .requested)
        XCTAssertEqual(counter.count, 1, "after the run unwound, Standard recovers again")
    }
}

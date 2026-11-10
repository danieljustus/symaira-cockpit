import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

/// A governor stand-in: loops like the real one (check `shouldContinue`, sleep)
/// and records the unwind, which is where the real governor restores the fans.
final class FakeGovernorRunner: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started = 0
    private(set) var restored = 0
    private(set) var profilesSeen: [FanProfile] = []
    var failure: Error?

    func runner() -> FanHelperEngine.GovernorRunner {
        { [self] profileProvider, shouldContinue, sleep in
            lock.lock(); started += 1; lock.unlock()
            defer { lock.lock(); restored += 1; lock.unlock() }
            while shouldContinue() {
                let profile = profileProvider()
                lock.lock()
                if profilesSeen.last != profile { profilesSeen.append(profile) }
                let failure = self.failure
                lock.unlock()
                if let failure { throw failure }
                sleep(0.05)
            }
        }
    }
}

/// A governor whose unwind (the restore) is held until the test releases it,
/// and which records whether two runs ever overlapped and what each run found.
final class SlowUnwindRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var active = 0
    private(set) var maxActive = 0
    private(set) var started = 0
    private(set) var unwound = 0
    /// Number of runs that finished unwinding before the n-th run began.
    private(set) var unwoundWhenStarted: [Int] = []

    func releaseOneUnwind() { release.signal() }

    func runner() -> FanHelperEngine.GovernorRunner {
        { [self] _, shouldContinue, sleep in
            lock.lock()
            active += 1; maxActive = max(maxActive, active)
            started += 1; unwoundWhenStarted.append(unwound)
            lock.unlock()
            while shouldContinue() { sleep(0.01) }
            // The restore: slow, as a governor blocked in an SMC call is.
            release.wait()
            lock.lock(); active -= 1; unwound += 1; lock.unlock()
        }
    }
}

final class FanHelperEngineTests: XCTestCase {
    func testRestartRightAfterStopWaitsForThePreviousRestoreBeforeStarting() {
        let slow = SlowUnwindRunner()
        let engine = FanHelperEngine(
            watchdog: HeartbeatWatchdog(timeout: 7, clock: { FakeClock().read() }),
            sleepSlice: 0.005, runner: slow.runner()
        )
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { slow.started == 1 })
        engine.stop(reason: .requested)
        // No waiting for idle: the first run is still restoring.
        engine.start(profile: .performance)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(slow.started, 1, "the second governor must not start while the first restores")
        XCTAssertEqual(slow.maxActive, 1)
        XCTAssertTrue(engine.snapshot.isGoverning, "the pending run counts as governing")

        slow.releaseOneUnwind()
        XCTAssertTrue(waitUntil { slow.started == 2 })
        XCTAssertEqual(slow.unwoundWhenStarted, [0, 1], "the 2nd run starts only after the 1st restored")
        XCTAssertEqual(slow.maxActive, 1)

        engine.stop(reason: .requested)
        slow.releaseOneUnwind()
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testARunStoppedWhileQueuedBehindARestoringRunNeverStarts() {
        let slow = SlowUnwindRunner()
        let engine = FanHelperEngine(
            watchdog: HeartbeatWatchdog(timeout: 7, clock: { FakeClock().read() }),
            sleepSlice: 0.005, runner: slow.runner()
        )
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { slow.started == 1 })
        engine.stop(reason: .requested)
        engine.start(profile: .performance)
        engine.stop(reason: .requested) // cancelled before it ever ran
        slow.releaseOneUnwind()
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(slow.started, 1, "a cancelled queued run must never capture or override fan state")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private func makeEngine(
        clock: FakeClock,
        runner: FakeGovernorRunner
    ) -> FanHelperEngine {
        FanHelperEngine(
            watchdog: HeartbeatWatchdog(timeout: 7, clock: { clock.read() }),
            sleepSlice: 0.005,
            runner: runner.runner()
        )
    }

    func testStartRunsTheGovernorOnTheRequestedProfile() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.profilesSeen == [.comfort] })
        XCTAssertTrue(engine.snapshot.isGoverning)
        XCTAssertEqual(engine.snapshot.profile, .comfort)
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testStartingWhileRunningRetargetsInsteadOfSpawningASecondGovernor() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.profilesSeen == [.comfort] })
        engine.start(profile: .performance)
        XCTAssertTrue(waitUntil { fake.profilesSeen == [.comfort, .performance] })
        XCTAssertEqual(fake.started, 1)
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testSystemProfileIsAStopNotAGovernedRun() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        engine.start(profile: .system)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(fake.restored, 1)
        XCTAssertEqual(engine.snapshot.lastStopReason, .profileSystem)
    }

    func testStopRestoresAndRecordsTheReason() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .performance)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(fake.restored, 1)
        XCTAssertEqual(engine.snapshot.lastStopReason, .requested)
    }

    // MARK: - Dead-man switch

    func testMissingHeartbeatRestoresAfterMoreThanTheTimeout() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })

        clock.advance(7)
        XCTAssertFalse(engine.watchdogTick(), "exactly at the limit must not trip")
        XCTAssertTrue(engine.snapshot.isGoverning)

        clock.advance(0.5)
        XCTAssertTrue(engine.watchdogTick())
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(fake.restored, 1)
        XCTAssertEqual(engine.snapshot.lastStopReason, .heartbeatTimeout)
    }

    func testHeartbeatsKeepTheGovernorAlive() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        for _ in 0..<10 {
            clock.advance(2)
            engine.heartbeat()
            XCTAssertFalse(engine.watchdogTick())
        }
        XCTAssertTrue(engine.snapshot.isGoverning)
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testWatchdogDoesNothingWhenIdle() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        clock.advance(60)
        XCTAssertFalse(engine.watchdogTick())
        XCTAssertEqual(fake.started, 0)
    }

    func testStartArmsTheWatchdogFresh() {
        // A long-idle helper must not trip the moment a run starts.
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        clock.advance(3_600)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        XCTAssertFalse(engine.watchdogTick())
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testConnectionInvalidationRestores() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        engine.connectionInvalidated()
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(fake.restored, 1)
        XCTAssertEqual(engine.snapshot.lastStopReason, .connectionInvalidated)
    }

    func testTerminateRestoresBeforeReturning() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .performance)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        engine.terminate(grace: 2)
        XCTAssertEqual(fake.restored, 1)
        XCTAssertFalse(engine.snapshot.isGoverning)
        XCTAssertEqual(engine.snapshot.lastStopReason, .terminated)
    }

    // MARK: - Governor's own failure policy

    func testGovernorFailureIsReportedAndLeavesTheEngineIdle() {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        fake.failure = Boom()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        XCTAssertEqual(fake.restored, 1)
        XCTAssertEqual(engine.snapshot.failure, "boom")
        XCTAssertEqual(engine.snapshot.lastStopReason, .governorFinished)
    }

    func testRestartAfterAStopStartsAFreshRun() {
        let clock = FakeClock()
        let fake = FakeGovernorRunner()
        let engine = makeEngine(clock: clock, runner: fake)
        engine.start(profile: .comfort)
        XCTAssertTrue(waitUntil { fake.started == 1 })
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
        engine.start(profile: .performance)
        XCTAssertTrue(waitUntil { fake.started == 2 })
        XCTAssertNil(engine.snapshot.failure)
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }
}

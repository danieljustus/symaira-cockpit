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

final class FanHelperEngineTests: XCTestCase {
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

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
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

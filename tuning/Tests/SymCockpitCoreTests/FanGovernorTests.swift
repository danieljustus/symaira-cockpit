import XCTest
@testable import SymCockpitCore

final class FanGovernorTests: XCTestCase {

    // MARK: - Per-tick decision

    func testSystemProfileNeverWrites() {
        XCTAssertNil(FanGovernor.nextFraction(profile: .system, temperature: 95, applied: nil))
        XCTAssertNil(FanGovernor.nextFraction(profile: .system, temperature: 95, applied: 0.4))
    }

    func testFirstTickAppliesTheCurveDirectly() throws {
        let curve = try XCTUnwrap(FanProfile.comfort.curve)
        let next = FanGovernor.nextFraction(profile: .comfort, temperature: 75, applied: nil)
        XCTAssertEqual(next ?? 0, curve.fraction(at: 75), accuracy: 0.0001)
    }

    /// Heat arrives faster than it leaves, so the governor is deliberately
    /// asymmetric: it follows the curve straight up.
    func testSpeedIncreaseIsImmediate() throws {
        let curve = try XCTUnwrap(FanProfile.comfort.curve)
        let next = FanGovernor.nextFraction(profile: .comfort, temperature: 85, applied: 0.30)
        XCTAssertEqual(next ?? 0, curve.fraction(at: 85), accuracy: 0.0001)
        XCTAssertEqual(next ?? 0, 1.0, accuracy: 0.0001)
    }

    /// …but ramps down slowly. Die temperature drops the instant a burst of
    /// work ends, and tracking it verbatim makes the fans audibly surge.
    func testSpeedDecreaseIsRateLimited() {
        let next = FanGovernor.nextFraction(profile: .comfort, temperature: 40, applied: 1.0)
        XCTAssertEqual(next ?? 0, 1.0 - FanGovernor.maxDecreasePerTick, accuracy: 0.0001)
    }

    func testDecreaseNeverOvershootsTheTarget() throws {
        let curve = try XCTUnwrap(FanProfile.comfort.curve)
        let target = curve.fraction(at: 74)
        // Already within one tick's step of the target: land on it, not below.
        let next = FanGovernor.nextFraction(
            profile: .comfort,
            temperature: 74,
            applied: target + FanGovernor.maxDecreasePerTick / 2
        )
        XCTAssertEqual(next ?? 0, target, accuracy: 0.0001)
    }

    /// A fan at a stable temperature is left alone rather than taking an SMC
    /// write every few seconds.
    func testSmallChangesAreNotWritten() throws {
        let curve = try XCTUnwrap(FanProfile.comfort.curve)
        let settled = curve.fraction(at: 65)
        XCTAssertNil(FanGovernor.nextFraction(profile: .comfort, temperature: 65, applied: settled))
    }

    /// "No reading" is not "cold". Dropping the fans because a sensor poll
    /// came back empty is exactly the wrong move on a hot chip.
    func testMissingTemperatureHoldsTheLastValue() {
        XCTAssertEqual(
            FanGovernor.nextFraction(profile: .performance, temperature: nil, applied: 0.8) ?? 0,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertNil(FanGovernor.nextFraction(profile: .performance, temperature: nil, applied: nil))
    }

    // MARK: - Loop behavior

    private func makeGovernor(
        keys: [String: FakeSMCKeyResult],
        connection: FakeSMCConnection? = nil
    ) -> (FanGovernor, FakeSMCConnection) {
        let conn = connection ?? FakeSMCConnection(isOpen: true, keys: keys)
        let smc = SMCService(connection: conn)
        let sensors = SensorService(smc: smc)
        let fanControl = FanControlService(smc: smc, sensors: sensors, sleep: { _ in })
        return (
            FanGovernor(fanControl: fanControl, sensors: sensors, config: TuneConfig(), sleep: { _ in }),
            conn
        )
    }

    private func fanKeys(
        dieCelsius: Double,
        targetRPM: Double = 2000,
        mode: UInt8 = 1
    ) -> [String: FakeSMCKeyResult] {
        func flt(_ v: Double) -> FakeSMCKeyResult {
            let raw = Float(v).bitPattern
            return FakeSMCKeyResult(dataType: smcEncodeKey("flt "), bytes: [
                UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF),
            ])
        }
        let ui8 = smcEncodeKey("ui8 ")
        return [
            "FNum": FakeSMCKeyResult(dataType: ui8, bytes: [1]),
            "F0Md": FakeSMCKeyResult(dataType: ui8, bytes: [mode]),
            "F0Ac": flt(targetRPM),
            "F0Tg": flt(targetRPM),
            "F0Mn": flt(2000),
            "F0Mx": flt(8000),
            "TCMz": flt(dieCelsius),
        ]
    }

    /// Moving the control back to the default position stops the loop — the
    /// governor re-reads the selection every tick, so a change of position
    /// takes effect without a second authorization prompt.
    func testLoopExitsWhenProfileReturnsToSystem() throws {
        let (governor, _) = makeGovernor(keys: fanKeys(dieCelsius: 85))
        let ticks = TickCounter()

        try governor.run(profileProvider: {
            ticks.count < 3 ? .comfort : .system
        }, onTick: { _, _ in ticks.increment() })

        XCTAssertEqual(ticks.count, 3)
    }

    func testLoopWritesTheFanTargetWhileGoverning() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85))
        let ticks = TickCounter()

        try governor.run(profileProvider: {
            ticks.count < 1 ? .performance : .system
        }, onTick: { _, _ in ticks.increment() })

        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "F0Tg" })
    }

    /// Leaving the loop must put the SMC back where it was found, including
    /// through a stop request — otherwise the fans stay pinned at whatever was
    /// last written.
    func testLoopRestoresOriginalStateOnExit() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85, targetRPM: 2500))
        let ticks = TickCounter()

        try governor.run(
            profileProvider: { .performance },
            shouldContinue: { ticks.count < 2 },
            onTick: { _, _ in ticks.increment() }
        )

        // The last thing written to the fan target is the captured original.
        let lastTarget = conn.writtenKeys.last { $0.key == "F0Tg" }
        XCTAssertEqual(
            smcConvertValue(dataType: smcEncodeKey("flt "), bytes: lastTarget?.bytes ?? []),
            2500,
            accuracy: 1.0
        )
        let lastMode = conn.writtenKeys.last { $0.key == "F0Md" }
        XCTAssertEqual(lastMode?.bytes, [1])
    }

    func testLoopDoesNothingForSystemProfile() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85))
        try governor.run(profileProvider: { .system })
        XCTAssertFalse(conn.writtenKeys.contains { $0.key == "F0Tg" })
    }

    // MARK: - Cool target

    private func fltResult(_ v: Double) -> FakeSMCKeyResult {
        let raw = Float(v).bitPattern
        return FakeSMCKeyResult(dataType: smcEncodeKey("flt "), bytes: [
            UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF),
        ])
    }

    /// A cool die (TCMz 50 °C) with hot cluster rows (Tp01–03 at 70 °C).
    private func clusterKeys() -> [String: FakeSMCKeyResult] {
        var keys = fanKeys(dieCelsius: 50)
        for key in ["Tp01", "Tp02", "Tp03"] { keys[key] = fltResult(70) }
        return keys
    }

    /// The governor reads the target from the selection every tick: the same
    /// sensors give full speed with a 60 °C target and the default speed
    /// without one.
    func testLoopRaisesTheFansForAnAverageAboveTheTarget() throws {
        let (governor, conn) = makeGovernor(keys: clusterKeys())
        let ticks = TickCounter()
        try governor.run(
            selectionProvider: { FanSelection(profile: .comfort, coolTargetCelsius: 60) },
            shouldContinue: { ticks.count < 1 },
            onTick: { _, _ in ticks.increment() }
        )
        // The restore on exit writes the original last; look at what was applied.
        let applied = conn.writtenKeys.filter { $0.key == "F0Tg" }.first
        let rpm = applied.map { smcConvertValue(dataType: smcEncodeKey("flt "), bytes: $0.bytes) }
        XCTAssertEqual(rpm ?? 0, 8000, accuracy: 1.0, "average 70 °C is above a 60 °C target: full speed")
    }

    func testLoopWithoutATargetIgnoresTheClusterRows() throws {
        let (governor, conn) = makeGovernor(keys: clusterKeys())
        let ticks = TickCounter()
        try governor.run(
            selectionProvider: { FanSelection(profile: .comfort) },
            shouldContinue: { ticks.count < 1 },
            onTick: { _, _ in ticks.increment() }
        )
        let applied = conn.writtenKeys.filter { $0.key == "F0Tg" }.first
        let rpm = applied.map { smcConvertValue(dataType: smcEncodeKey("flt "), bytes: $0.bytes) } ?? 0
        XCTAssertLessThan(rpm, 5000, "a 50 °C die on the default Cool curve is nowhere near full speed")
    }

    func testLoopPicksUpAChangedTargetOnTheNextTick() throws {
        let (governor, conn) = makeGovernor(keys: clusterKeys())
        let ticks = TickCounter()
        try governor.run(
            selectionProvider: {
                // First tick: no target. From the second tick on: 60 °C.
                ticks.count < 1
                    ? FanSelection(profile: .comfort)
                    : FanSelection(profile: .comfort, coolTargetCelsius: 60)
            },
            shouldContinue: { ticks.count < 2 },
            onTick: { _, _ in ticks.increment() }
        )
        let applied = conn.writtenKeys.filter { $0.key == "F0Tg" }.map {
            smcConvertValue(dataType: smcEncodeKey("flt "), bytes: $0.bytes)
        }
        XCTAssertGreaterThanOrEqual(applied.count, 2)
        XCTAssertLessThan(applied[0], 5000)
        XCTAssertEqual(applied[1], 8000, accuracy: 1.0)
    }

    /// With no cluster row at all the hotspot rows stand in for the average, so
    /// the feature degrades instead of vanishing: a 50 degC chip against a
    /// 55 degC target is 5 degC short of it, which the shifted curve answers
    /// with more than the default curve's answer at 50 degC.
    func testLoopUsesTheHotspotAsTheAverageWhenNoClusterRowExists() throws {
        func appliedRPM(target: Double?) throws -> Double {
            let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 50))
            let ticks = TickCounter()
            try governor.run(
                selectionProvider: { FanSelection(profile: .comfort, coolTargetCelsius: target) },
                shouldContinue: { ticks.count < 1 },
                onTick: { _, _ in ticks.increment() }
            )
            let applied = conn.writtenKeys.filter { $0.key == "F0Tg" }.first
            return applied.map { smcConvertValue(dataType: smcEncodeKey("flt "), bytes: $0.bytes) } ?? 0
        }
        let withoutTarget = try appliedRPM(target: nil)
        let relaxed = try appliedRPM(target: 85)
        let tight = try appliedRPM(target: 55)
        XCTAssertEqual(relaxed, withoutTarget, accuracy: 1.0, "85 degC is the default curve itself")
        XCTAssertGreaterThan(tight, withoutTarget)
    }

    func testLoopIgnoresTheTargetOnMax() throws {
        let (governor, conn) = makeGovernor(keys: clusterKeys())
        let ticks = TickCounter()
        try governor.run(
            selectionProvider: { FanSelection(profile: .performance, coolTargetCelsius: 50) },
            shouldContinue: { ticks.count < 1 },
            onTick: { _, _ in ticks.increment() }
        )
        let applied = conn.writtenKeys.filter { $0.key == "F0Tg" }.first
        let rpm = applied.map { smcConvertValue(dataType: smcEncodeKey("flt "), bytes: $0.bytes) } ?? 0
        // Max at 50 °C is 0.55 of the range, not full speed.
        XCTAssertLessThan(rpm, 7000)
    }

    // MARK: - Failure bounds

    /// A short sensor gap is held through, so a single empty poll never
    /// drops the fans on a hot chip.
    func testLoopHoldsThroughAShortTemperatureGap() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85))
        let die = conn.keys["TCMz"]
        let ticks = TickCounter()

        try governor.run(
            profileProvider: { .performance },
            shouldContinue: { ticks.count < 6 },
            onTick: { _, _ in
                ticks.increment()
                // Readings vanish for the ticks just short of the bound, then return.
                let missing = ticks.count < FanGovernor.maxConsecutiveMissingTemperatures
                conn.keys["TCMz"] = missing ? nil : die
            }
        )

        XCTAssertEqual(ticks.count, 6)
    }

    /// Holding the last speed forever would pin the fans at a constant speed
    /// with nothing governing it, so a lasting gap hands them back.
    func testLoopHandsBackAfterConsecutiveMissingTemperatures() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85, targetRPM: 2500))
        let ticks = TickCounter()

        XCTAssertThrowsError(try governor.run(
            profileProvider: { .performance },
            shouldContinue: { ticks.count < 20 },
            onTick: { _, _ in
                ticks.increment()
                conn.keys["TCMz"] = nil
            }
        )) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
        }

        XCTAssertEqual(ticks.count, FanGovernor.maxConsecutiveMissingTemperatures)
        let lastTarget = conn.writtenKeys.last { $0.key == "F0Tg" }
        XCTAssertEqual(
            smcConvertValue(dataType: smcEncodeKey("flt "), bytes: lastTarget?.bytes ?? []),
            2500,
            accuracy: 1.0
        )
    }

    /// The deadband means a steady temperature writes nothing, so without a
    /// read-back the governor would not notice the firmware taking the fans
    /// back (for example across sleep). It re-asserts the applied state.
    func testLoopReassertsWhenTheFirmwareTakesTheFansBack() throws {
        // Firmware mode 3, so the restore on exit cannot pass for a re-assert.
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85, mode: 3))
        let ui8 = smcEncodeKey("ui8 ")
        let ticks = TickCounter()

        try governor.run(
            profileProvider: { .performance },
            shouldContinue: { ticks.count < 4 },
            onTick: { _, _ in
                ticks.increment()
                if ticks.count == 1 {
                    conn.keys["F0Md"] = FakeSMCKeyResult(dataType: ui8, bytes: [3])
                    conn.writtenKeys.removeAll()
                }
            }
        )

        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "F0Md" && $0.bytes == [1] })
    }

    /// When re-asserting cannot make the SMC hold the applied state, the
    /// governor stops claiming control and restores what it found.
    func testLoopHandsBackWhenTheAppliedStateWillNotHold() throws {
        let (governor, conn) = makeGovernor(keys: fanKeys(dieCelsius: 85, targetRPM: 2500))
        let ticks = TickCounter()
        conn.writeHandler = { key, dataType, bytes in
            // After the first tick the firmware ignores every target write.
            if key == "F0Tg", ticks.count >= 1 { return true }
            conn.keys[key] = FakeSMCKeyResult(dataType: dataType, bytes: bytes)
            return true
        }

        XCTAssertThrowsError(try governor.run(
            profileProvider: { .performance },
            shouldContinue: { ticks.count < 20 },
            onTick: { _, _ in
                ticks.increment()
                if ticks.count == 1 { conn.keys["F0Tg"] = conn.keys["F0Mn"] }
            }
        )) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
        }

        XCTAssertEqual(ticks.count, FanGovernor.maxConsecutiveUnverifiedTicks)
        let lastTarget = conn.writtenKeys.last { $0.key == "F0Tg" }
        XCTAssertEqual(
            smcConvertValue(dataType: smcEncodeKey("flt "), bytes: lastTarget?.bytes ?? []),
            2500,
            accuracy: 1.0
        )
    }
}

/// Tick counter shared between the loop's `@Sendable` closures.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

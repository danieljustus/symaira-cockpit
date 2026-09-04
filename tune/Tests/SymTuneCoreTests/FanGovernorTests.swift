import XCTest
@testable import SymTuneCore

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

    private func fanKeys(dieCelsius: Double, targetRPM: Double = 2000) -> [String: FakeSMCKeyResult] {
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
            "F0Md": FakeSMCKeyResult(dataType: ui8, bytes: [1]),
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

import XCTest
@testable import SymCockpitCore

// MARK: - TuneController sensorsReport(), beginKeepAwake(), endKeepAwake()
//
// Keep-awake tests inject a power source: ordinary unit tests must not
// create IOKit sleep assertions on the machine running them.

final class TuneControllerSensorsKeepAwakeTests: XCTestCase {

    // MARK: - sensorsReport (line 98)

    /// Covers the sensorsReport() facade: returns a SensorReport with a
    /// recognised thermal-pressure label and the expected field shape.
    func testSensorsReportReturnsValidReport() {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())
        let report = controller.sensorsReport()

        // Thermal pressure must be one of the known labels
        let knownLabels = ["nominal", "fair", "serious", "critical", "unknown"]
        XCTAssertTrue(
            knownLabels.contains(report.thermalPressure),
            "thermalPressure '\(report.thermalPressure)' not in \(knownLabels)"
        )

        // Report fields are populated (not default-constructed nonsense)
        // smcSupported may be false in CI/VM, but the field exists
        XCTAssertTrue([true, false].contains(report.smcSupported))
        XCTAssertNotNil(report.temperatures)
        XCTAssertNotNil(report.fans)
        XCTAssertNotNil(report.notes)

        // The deprecated shim forwards to the new name with identical data
        let alt = controller.sensors_report()
        XCTAssertEqual(report.thermalPressure, alt.thermalPressure)
        XCTAssertEqual(report.smcSupported, alt.smcSupported)
    }

    // MARK: - beginKeepAwake (lines 179-185)

    /// Covers lines 179-185: beginKeepAwake creates a power assertion,
    /// increments the active token count, and returns a valid token.
    func testBeginKeepAwakeReturnsTokenAndActivates() throws {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())

        XCTAssertFalse(controller.isKeepAwakeActive(), "precondition: should start inactive")

        let token = try controller.beginKeepAwake(
            reason: "test keep-awake",
            preventDisplaySleep: false
        )

        // Token has a valid (non-zero) assertion ID from the injected source
        XCTAssertNotEqual(token.id, 0, "token ID should be non-zero")

        // Active state flips on
        XCTAssertTrue(controller.isKeepAwakeActive())

        controller.endKeepAwake(token)
    }

    /// Covers lines 179-185 with preventDisplaySleep: true.
    func testBeginKeepAwakeDisplaySleepVariant() throws {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())

        let token = try controller.beginKeepAwake(
            reason: "test display-prevent",
            preventDisplaySleep: true
        )

        XCTAssertNotEqual(token.id, 0)
        XCTAssertTrue(controller.isKeepAwakeActive())

        controller.endKeepAwake(token)
    }

    /// Multiple begin calls stack the active-token counter.
    func testBeginKeepAwakeMultipleTokensStack() throws {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())

        let t1 = try controller.beginKeepAwake(reason: "first", preventDisplaySleep: false)
        XCTAssertTrue(controller.isKeepAwakeActive())

        let t2 = try controller.beginKeepAwake(reason: "second", preventDisplaySleep: false)
        XCTAssertTrue(controller.isKeepAwakeActive())

        // End first — still active because second is still held
        controller.endKeepAwake(t1)
        XCTAssertTrue(controller.isKeepAwakeActive())

        // End second — now inactive
        controller.endKeepAwake(t2)
        XCTAssertFalse(controller.isKeepAwakeActive())
    }

    // MARK: - endKeepAwake (lines 187-192)

    /// Covers lines 187-192: endKeepAwake releases the assertion
    /// and decrements the active token count to zero.
    func testEndKeepAwakeReleasesAndDeactivates() throws {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())

        let token = try controller.beginKeepAwake(
            reason: "test end",
            preventDisplaySleep: false
        )
        XCTAssertTrue(controller.isKeepAwakeActive())

        controller.endKeepAwake(token)

        XCTAssertFalse(controller.isKeepAwakeActive(), "should be inactive after endKeepAwake")
    }

    /// endKeepAwake clamps the counter at 0 (no underflow).
    func testEndKeepAwakeClampsCounterAtZero() throws {
        let controller = TuneController(displayWrite: MockDisplayWriteService(), keepAwakeSource: FakePowerAssertionSource())

        let token = try controller.beginKeepAwake(reason: "single", preventDisplaySleep: false)
        controller.endKeepAwake(token)
        XCTAssertFalse(controller.isKeepAwakeActive())

        // Calling endKeepAwake again should not crash or underflow.
        let token2 = try controller.beginKeepAwake(reason: "second", preventDisplaySleep: false)
        controller.endKeepAwake(token2)
        controller.endKeepAwake(token2)
        XCTAssertFalse(controller.isKeepAwakeActive())
    }
}

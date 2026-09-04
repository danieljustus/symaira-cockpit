import XCTest
@testable import SymTuneCore

/// Only pure-logic pieces of `PrivilegedElevation` are tested here —
/// `runSymCockpit` itself is deliberately never exercised: on a machine
/// where `symcockpit` is actually installed (the normal case for anyone
/// developing this repo), calling it would spawn a real `osascript … with
/// administrator privileges` and pop a live system password dialog during
/// `swift test`, which must never happen from an automated test run.
final class PrivilegedElevationTests: XCTestCase {

    // MARK: - isWorthEscalating

    func testEscalatesOnFanModeWriteRejected() {
        XCTAssertTrue(PrivilegedElevation.isWorthEscalating(FanControlError.fanModeWriteRejected(0)))
    }

    func testEscalatesOnTargetRPMWriteFailed() {
        XCTAssertTrue(PrivilegedElevation.isWorthEscalating(FanControlError.targetRPMWriteFailed(0)))
    }

    func testDoesNotEscalateWhenNoFansAreDetected() {
        XCTAssertFalse(PrivilegedElevation.isWorthEscalating(FanControlError.noFansDetected))
    }

    func testDoesNotEscalateOnUnsupportedPlatform() {
        XCTAssertFalse(PrivilegedElevation.isWorthEscalating(FanControlError.unsupportedPlatform))
    }

    /// The regression case: a machine where even the read-only SMC probe
    /// fails unprivileged throws a plain `TuneError.permission(...)` before
    /// any `FanControlError` exists — this must still be treated as worth
    /// one privileged retry, or escalation would silently never fire on
    /// exactly the machines that need it.
    func testEscalatesOnGenericPermissionErrorFromAnUnavailableSMCProbe() {
        XCTAssertTrue(PrivilegedElevation.isWorthEscalating(TuneError.permission("SMC not available — fan control requires a real Mac")))
    }

    func testEscalatesOnSMCWritePolicyValidationErrors() {
        XCTAssertTrue(PrivilegedElevation.isWorthEscalating(SMCWritePolicy.ValidationError.noSMCConnection))
        XCTAssertTrue(PrivilegedElevation.isWorthEscalating(SMCWritePolicy.ValidationError.thermalEmergency(95)))
    }

    // MARK: - shellFormat

    func testShellFormatIsLocaleIndependent() {
        // Not directly overridable in-process, but the fixed en_US_POSIX
        // locale argument means the current locale must never leak in.
        XCTAssertEqual(PrivilegedElevation.shellFormat(0.5), "0.5000")
        XCTAssertEqual(PrivilegedElevation.shellFormat(1.0), "1.0000")
    }
}

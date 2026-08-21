import XCTest
@testable import SymTuneCore

// MARK: - TuneController Fan / Charge-Limit Tests

final class TuneControllerFanChargeTests: XCTestCase {
    private func makeController(
        keys: [String: FakeSMCKeyResult] = [:],
        batteryResult: BatterySourceResult = .unavailable
    ) -> TuneController {
        let smc = SMCService(connection: FakeSMCConnection(isOpen: true, keys: keys))
        let batterySource = FakeBatterySource(result: batteryResult)
        return TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: smc,
            batterySource: batterySource
        )
    }

    private func fpe2(_ value: Double) -> FakeSMCKeyResult {
        let raw = UInt16((value * 256.0).rounded())
        return FakeSMCKeyResult(dataType: smcEncodeKey("fpe2"), bytes: [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)])
    }

    private func ui8(_ value: UInt8) -> FakeSMCKeyResult {
        FakeSMCKeyResult(dataType: smcEncodeKey("ui8 "), bytes: [value])
    }

    private func ui32(_ value: UInt32) -> FakeSMCKeyResult {
        FakeSMCKeyResult(
            dataType: smcEncodeKey("ui32"),
            bytes: [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        )
    }

    private func flt(_ value: Double) -> FakeSMCKeyResult {
        let raw = Float(value).bitPattern
        return FakeSMCKeyResult(
            dataType: smcEncodeKey("flt "),
            bytes: [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        )
    }

    func testApplyFanSuccess() {
        let controller = makeController(keys: [
            "FNum": ui8(1),
            "F0Md": ui8(3),
            "F0Tg": flt(3000),
            "F0Mx": flt(6000),
            "F0Mn": flt(1200),
            "Tp01": fpe2(30.0)
        ])
        XCTAssertNoThrow(try controller.applyFan(fraction: 0.5))
    }

    func testApplyFanNoFansDetected() {
        let controller = makeController(keys: [
            "FNum": ui8(0),
            "Tp01": fpe2(30.0)
        ])
        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("SMC reports no fans") || message.contains("unsupported"), "unexpected: \(message)")
        }
    }

    func testRestoreFanAuto() {
        let controller = makeController(keys: [
            "FNum": ui8(1),
            "F0Md": ui8(3),
            "F0Tg": flt(3000)
        ])
        XCTAssertNoThrow(try controller.restoreFanAuto())
    }

    func testRestoreFanAutoNoFans() {
        let controller = makeController(keys: [
            "FNum": ui8(0),
        ])
        XCTAssertThrowsError(try controller.restoreFanAuto()) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("no fans") || message.contains("unsupported"), "unexpected: \(message)")
        }
    }

    func testApplyChargeLimitSuccess() {
        let controller = makeController(
            keys: ["CHTE": ui32(0)],
            batteryResult: .success(BatteryProperties(externalConnected: true))
        )
        XCTAssertNoThrow(try controller.applyChargeLimit(percent: 80))
    }

    func testApplyChargeLimitRequiresACPower() {
        let controller = makeController(
            keys: ["CHTE": ui32(0)],
            batteryResult: .success(BatteryProperties(externalConnected: false))
        )
        XCTAssertThrowsError(try controller.applyChargeLimit(percent: 80)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("AC power"), "unexpected: \(message)")
        }
    }

    func testClearChargeLimit() {
        let controller = makeController(keys: ["CHTE": ui32(0)])
        XCTAssertNoThrow(try controller.clearChargeLimit())
    }

    func testActiveFanFraction() {
        let controller = makeController(keys: [
            "FNum": ui8(1),
            "F0Md": ui8(1),
            "F0Tg": flt(3000),
            "F0Mx": flt(6000)
        ])
        XCTAssertEqual(controller.activeOverrides().fanFraction ?? 0, 0.5, accuracy: 0.01)
    }

    func testActiveChargeLimitPercent() throws {
        let controller = makeController(keys: ["CHTE": ui32(1)])
        // A hardware inhibit bit with no limit applied by this process is not
        // reported as an override — only limits this process set are tracked.
        XCTAssertNil(controller.activeOverrides().chargeLimitPercent)
        XCTAssertNil(controller.activeOverrides().chargeLimitState)

        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let batterySource = FakeBatterySource(result: .success(BatteryProperties(externalConnected: true)))
        let controller2 = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller2.applyChargeLimit(percent: 80)
        XCTAssertEqual(controller2.activeOverrides().chargeLimitPercent, 80)
        XCTAssertEqual(controller2.activeOverrides().chargeLimitState, .active)

        // The exact percent the user requested is reported (not a hardcoded 80).
        try controller2.clearChargeLimit()
        try controller2.applyChargeLimit(percent: 85)
        XCTAssertEqual(controller2.activeOverrides().chargeLimitPercent, 85)
    }

    func testChargeLimitLapseDetectedWhenHardwareDisagrees() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let batterySource = FakeBatterySource(result: .success(BatteryProperties(externalConnected: true)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller.applyChargeLimit(percent: 80)
        XCTAssertEqual(controller.activeOverrides().chargeLimitState, .active)

        // Simulate the volatile Apple Silicon inhibit bit resetting (sleep,
        // firmware decision) behind the process's back.
        conn.keys["CHTE"] = FakeSMCKeyResult(dataType: smcEncodeKey("ui32"), bytes: [0, 0, 0, 0])
        XCTAssertEqual(controller.activeOverrides().chargeLimitPercent, 80)
        XCTAssertEqual(controller.activeOverrides().chargeLimitState, .lapsed)

        // A clear restores honest reporting.
        try controller.clearChargeLimit()
        XCTAssertNil(controller.activeOverrides().chargeLimitPercent)
        XCTAssertNil(controller.activeOverrides().chargeLimitState)
    }

    func testChargeLimitLapseDetectedOnCH0B() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CH0B": ui8(0)])
        let batterySource = FakeBatterySource(result: .success(BatteryProperties(externalConnected: true)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller.applyChargeLimit(percent: 80)
        XCTAssertEqual(controller.activeOverrides().chargeLimitState, .active)

        conn.keys["CH0B"] = FakeSMCKeyResult(dataType: smcEncodeKey("ui8 "), bytes: [0])
        XCTAssertEqual(controller.activeOverrides().chargeLimitState, .lapsed)
    }

    // MARK: - Wake re-assert + hysteresis (part B of #232)

    private func battery(_ percent: Int) -> BatteryProperties {
        BatteryProperties(
            externalConnected: true,
            rawMaxCapacity: 100,
            rawCurrentCapacity: percent
        )
    }

    func testReconcileReassertsLapsedLimitAfterWake() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let batterySource = FakeBatterySource(result: .success(battery(80)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller.applyChargeLimit(percent: 80)
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1])

        // Wake: the volatile inhibit bit reset behind the process's back.
        conn.keys["CHTE"] = FakeSMCKeyResult(dataType: smcEncodeKey("ui32"), bytes: [0, 0, 0, 0])
        controller.reconcileChargeLimit()

        // Re-asserted because the battery is still at/above the target.
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1])
        XCTAssertEqual(controller.activeOverrides().chargeLimitState, .active)
    }

    func testReconcileKeepsActiveLimitWithoutRewrite() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let batterySource = FakeBatterySource(result: .success(battery(80)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller.applyChargeLimit(percent: 80)
        let writesBefore = conn.writtenKeys.count

        controller.reconcileChargeLimit()

        XCTAssertEqual(conn.writtenKeys.count, writesBefore, "no redundant writes while the limit is active")
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1])
    }

    func testReconcileHoldsInsideHysteresisBand() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let batterySource = FakeBatterySource(result: .success(battery(80)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        try controller.applyChargeLimit(percent: 80)

        // 76% is inside the band (80 - 5 hysteresis): still inhibited.
        batterySource.result = .success(battery(76))
        controller.reconcileChargeLimit()
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1], "no release inside the hysteresis band")

        // 75% is at the band edge: release.
        batterySource.result = .success(battery(75))
        controller.reconcileChargeLimit()
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 0], "inhibit released at target - hysteresis")
    }

    func testReconcileDoesNothingWithoutConfiguredLimit() {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        let batterySource = FakeBatterySource(result: .success(battery(80)))
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: conn),
            batterySource: batterySource
        )
        controller.reconcileChargeLimit()
        XCTAssertTrue(conn.writtenKeys.isEmpty, "no reconcile writes without a configured limit")
    }
}

// MARK: - TuneController Error Mapping Tests

final class TuneControllerErrorMappingTests: XCTestCase {
    func testMapFanControlError() {
        XCTAssertEqual(mapFanControlError(.noFansDetected).description, "unsupported: SMC reports no fans; fan control is unavailable")
        XCTAssertEqual(mapFanControlError(.fanModeWriteRejected(0)).description, "permission error: SMC rejected manual mode for fan 0; run with sudo")
        XCTAssertEqual(mapFanControlError(.targetRPMWriteFailed(1)).description, "permission error: SMC rejected target RPM for fan 1")
        XCTAssertEqual(mapFanControlError(.unsupportedPlatform).description, "unsupported: Fan control is not supported on this platform")
    }

    func testMapValidationError() {
        XCTAssertEqual(mapValidationError(.noSMCConnection).description, "permission error: SMC not available for write")
        XCTAssertEqual(mapValidationError(.thermalEmergency(95.0)).description, "permission error: thermal emergency at 95.0°C; refusing write")
        XCTAssertEqual(mapValidationError(.fanMaxRPMUnavailable(0)).description, "unsupported: SMC did not report maximum RPM for fan 0")
        XCTAssertEqual(mapValidationError(.chargeLimitNoACPower).description, "permission error: charge limit requires AC power and SMC write access")
    }
}

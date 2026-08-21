import XCTest
@testable import SymTuneCore

// MARK: - TuneController Write-Method Catch-Block Coverage
//
// These tests exercise the error (catch) branches of TuneController's write
// methods by injecting failures through fakes. Each test targets specific
// uncovered lines in TuneController.swift, verified via llvm-cov.

// MARK: - Display Write Error Paths

final class TuneControllerDisplayWriteErrorTests: XCTestCase {

    /// Covers lines 280-281: applyBuiltinBrightness catch block.
    func testApplyBuiltinBrightnessErrorPath() throws {
        let mock = MockDisplayWriteService()
        mock.brightness = 0.5
        mock.setBuiltinBrightnessError = TuneError.failed("display write refused")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.applyBuiltinBrightness(0.8)) { error in
            guard case TuneError.failed(let msg) = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
            XCTAssertEqual(msg, "display write refused")
        }

        // Verify history logged the failure
        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "brightness.set")
        XCTAssertEqual(entry?.requestedValue, 0.8)
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
        XCTAssertNil(entry?.appliedValue)
    }

    /// Covers lines 293-294: applyExtendedBrightness catch block.
    func testApplyExtendedBrightnessErrorPath() throws {
        let mock = MockDisplayWriteService()
        mock.applyExtendedBrightnessError = TuneError.failed("EDR layer failed")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.applyExtendedBrightness(1.3)) { error in
            guard case TuneError.failed(let msg) = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
            XCTAssertEqual(msg, "EDR layer failed")
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "extbright.set")
        XCTAssertEqual(entry?.requestedValue, 1.3)
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
        XCTAssertNil(entry?.appliedValue)
    }

    /// Covers lines 324-325: applyWarmth catch block.
    func testApplyWarmthErrorPath() throws {
        let mock = MockDisplayWriteService()
        mock.applyWarmthError = TuneError.failed("gamma LUT failed")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.applyWarmth(0.5)) { error in
            guard case TuneError.failed(let msg) = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
            XCTAssertEqual(msg, "gamma LUT failed")
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "warmth.set")
        XCTAssertEqual(entry?.requestedValue, 0.5)
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
        XCTAssertNil(entry?.appliedValue)
    }

    /// Covers lines 334-335: resetWarmth catch block.
    func testResetWarmthErrorPath() throws {
        let mock = MockDisplayWriteService()
        mock.resetWarmthError = TuneError.failed("color sync restore failed")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.resetWarmth()) { error in
            guard case TuneError.failed(let msg) = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
            XCTAssertEqual(msg, "color sync restore failed")
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "warmth.reset")
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
    }
}

// MARK: - Profile Error Paths

final class TuneControllerProfileErrorTests: XCTestCase {

    /// Covers lines 352-353: saveProfile catch block.
    /// Uses a dataDir that is a regular file (not a directory) so disk writes fail.
    /// History can't function with a broken dataDir, so we only verify the error is thrown.
    func testSaveProfileErrorPath() throws {
        let fileAsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-test-\(UUID().uuidString)")
        // Write a file where the directory should be so ProfileService can't create it
        try "dummy".write(to: fileAsDir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileAsDir) }

        let mock = MockDisplayWriteService()
        let controller = TuneController(config: TuneConfig(), displayWrite: mock, dataDir: fileAsDir)

        let profile = try TuneProfile(name: "test-save-err", brightness: 0.5)
        XCTAssertThrowsError(try controller.saveProfile(profile)) { error in
            // ProfileService.saveProfile throws a disk I/O error
            XCTAssertTrue("\(error)".contains("No such file") || "\(error)".contains("not a directory")
                        || "\(error)".contains("directory"), "unexpected: \(error)")
        }
    }

    /// Covers lines 370-371: deleteProfile catch block.
    /// Uses an invalid profile name ("//") so ProfileService.deleteProfile throws TuneError.usage.
    func testDeleteProfileErrorPath() throws {
        let mock = MockDisplayWriteService()
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.deleteProfile(name: "//")) { error in
            guard case TuneError.usage = error else {
                return XCTFail("expected TuneError.usage, got \(error)")
            }
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "profile.delete")
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
    }

    /// Covers lines 388-389: applyProfile catch block.
    /// Triggers a brightness failure inside applyProfile, which re-throws through applyProfile's catch.
    func testApplyProfileErrorPath() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-profile-err-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mock = MockDisplayWriteService()
        mock.brightness = 0.5
        mock.setBuiltinBrightnessError = TuneError.failed("display broken")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock, dataDir: tmpDir)

        let profile = try TuneProfile(name: "test-profile-err", brightness: 0.8)
        XCTAssertThrowsError(try controller.applyProfile(profile)) { error in
            guard case TuneError.failed(let msg) = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
            XCTAssertEqual(msg, "display broken")
        }

        let history = controller.getHistory()
        let brightnessEntry = history.last { $0.action == "brightness.set" }
        XCTAssertNotNil(brightnessEntry)
        XCTAssertEqual(brightnessEntry?.result, "failed")

        let profileEntry = history.last { $0.action == "profile.load" }
        XCTAssertNotNil(profileEntry)
        XCTAssertEqual(profileEntry?.result, "failed")
        XCTAssertNotNil(profileEntry?.errorReason)
    }
}

// MARK: - Fan / Charge Error Paths

final class TuneControllerFanChargeErrorTests: XCTestCase {

    // MARK: - Helpers

    private func fpe2(_ value: Double) -> FakeSMCKeyResult {
        let raw = UInt16((value * 256.0).rounded())
        return FakeSMCKeyResult(
            dataType: smcEncodeKey("fpe2"),
            bytes: [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        )
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

    /// Covers lines 440-441: applyFan SMCWritePolicy.ValidationError catch block.
    /// Provides a high temperature sensor reading (>90 °C) so requireThermalHeadroom
    /// throws .thermalEmergency, which is caught and mapped via mapValidationError.
    func testApplyFanValidationErrorPath() throws {
        let fakeSMC = FakeSMCConnection(isOpen: true, keys: [
            "FNum": ui8(1),
            "Tp01": fpe2(95.0),  // above thermalOverrideCelsius (90.0)
        ])
        let smc = SMCService(connection: fakeSMC)
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: smc,
            batterySource: FakeBatterySource(result: .unavailable)
        )

        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5)) { error in
            guard case TuneError.permission(let msg) = error else {
                return XCTFail("expected TuneError.permission (mapped from ValidationError), got \(error)")
            }
            XCTAssertTrue(msg.contains("thermal emergency"), "unexpected: \(msg)")
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "fan.set")
        XCTAssertEqual(entry?.requestedValue, 0.5)
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
        XCTAssertNil(entry?.appliedValue)
    }

    /// Covers lines 442-444: applyFan generic catch block.
    /// SMC is unavailable (isOpen: false), so FanControlService.applyFan throws
    /// TuneError.permission, which is NOT a FanControlError or ValidationError
    /// and therefore falls through to the generic catch.
    func testApplyFanGenericErrorPath() throws {
        let fakeSMC = FakeSMCConnection(isOpen: false)
        let smc = SMCService(connection: fakeSMC)
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: smc,
            batterySource: FakeBatterySource(result: .unavailable)
        )

        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5)) { error in
            guard case TuneError.permission(let msg) = error else {
                return XCTFail("expected TuneError.permission, got \(error)")
            }
            XCTAssertTrue(msg.contains("SMC not available"), "unexpected: \(msg)")
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "fan.set")
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
        XCTAssertNil(entry?.appliedValue)
    }

    /// Covers lines 482-483: clearChargeLimit generic catch block.
    /// Configures FakeSMCConnection to reject CHTE writes so
    /// ChargeLimitService.clearChargeLimit throws ChargeLimitError.allowWriteFailed.
    func testClearChargeLimitErrorPath() throws {
        let fakeSMC = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": ui32(0)
        ])
        // Reject CHTE writes to trigger allowWriteFailed
        fakeSMC.writeHandler = { key, _, _ in
            key != "CHTE"
        }
        let smc = SMCService(connection: fakeSMC)
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: smc,
            batterySource: FakeBatterySource(result: .unavailable)
        )

        XCTAssertThrowsError(try controller.clearChargeLimit()) { error in
            guard case ChargeLimitError.allowWriteFailed = error else {
                return XCTFail("expected ChargeLimitError.allowWriteFailed, got \(error)")
            }
        }

        let history = controller.getHistory()
        let entry = history.last
        XCTAssertEqual(entry?.action, "battery-limit.clear")
        XCTAssertEqual(entry?.result, "failed")
        XCTAssertNotNil(entry?.errorReason)
    }
}

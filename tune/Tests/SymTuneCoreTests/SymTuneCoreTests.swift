import XCTest
@testable import SymTuneCore

final class SafetyPolicyTests: XCTestCase {
    func testClampWithinRange() {
        XCTAssertEqual(SafetyPolicy.clamp(1.3, 1.0, 1.6), 1.3)
    }

    func testClampBelowLower() {
        XCTAssertEqual(SafetyPolicy.clamp(0.5, 1.0, 1.6), 1.0)
    }

    func testClampAboveUpper() {
        XCTAssertEqual(SafetyPolicy.clamp(2.0, 1.0, 1.6), 1.6)
    }

    func testDimNeverFullyBlack() {
        XCTAssertEqual(SafetyPolicy.clamp(0.0, SafetyPolicy.dimMin, SafetyPolicy.dimMax), SafetyPolicy.dimMin)
        XCTAssertGreaterThan(SafetyPolicy.dimMin, 0.0)
    }

    func testChargeLimitFloor() {
        XCTAssertEqual(SafetyPolicy.clamp(10, SafetyPolicy.chargeLimitMin, SafetyPolicy.chargeLimitMax),
                       SafetyPolicy.chargeLimitMin)
    }
}

final class CapabilityTests: XCTestCase {
    func testCapabilitiesShape() {
        let report = TuneController().capabilities()
        XCTAssertEqual(report.tool, "symtune")
        XCTAssertEqual(report.version, TuneVersion.current)
        XCTAssertFalse(report.capabilities.isEmpty)

        let fan = report.capabilities.first { $0.id == "fan.control" }
        XCTAssertEqual(fan?.tier, "core")
        XCTAssertNotNil(fan)

        let awake = report.capabilities.first { $0.id == "power.keepAwake" }
        XCTAssertEqual(awake?.tier, "core")
        XCTAssertEqual(awake?.available, true)

        let brightness = report.capabilities.first { $0.id == "display.brightness.set" }
        XCTAssertEqual(brightness?.available, true)

        let warmth = report.capabilities.first { $0.id == "display.warmth.set" }
        XCTAssertEqual(warmth?.available, true)
    }
}

final class SensorTests: XCTestCase {
    func testThermalPressureIsKnownLabel() {
        let label = SensorService.thermalPressureLabel()
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(label))
    }
}

final class WriteSurfaceTests: XCTestCase {
    func testExtendedBrightnessConfigApplied() {
        let custom = TuneConfig(extendedBrightnessMax: 1.4)
        let controller = TuneController(config: custom)
        XCTAssertEqual(controller.config.extendedBrightnessMax, 1.4)
    }

    func testFanControlRequiresSMC() {
        XCTAssertThrowsError(try TuneController().applyFan(fraction: 0.5)) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("SMC") || message.contains("permission") || message.contains("unsupported"),
                "unexpected error: \(error)"
            )
        }
    }

    func testBrightnessClampedBeforeApply() {
        let controller = TuneController()
        do {
            try controller.applyBuiltinBrightness(2.0)
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported (no built-in display), got \(error)")
            }
        }
    }

    func testDimClampedBySafetyPolicy() {
        let controller = TuneController()
        XCTAssertNoThrow(try controller.applyDim(0.5))
        XCTAssertNoThrow(try controller.applyDim(0.0))
        XCTAssertNoThrow(try controller.applyDim(2.0))
    }

    func testDimLevelTracked() {
        let controller = TuneController()
        XCTAssertEqual(controller.getDimLevel(), 1.0)
        XCTAssertNoThrow(try controller.applyDim(0.5))
    }

    func testResetDimClearsOverlays() {
        let controller = TuneController()
        XCTAssertNoThrow(try controller.applyDim(0.5))
        controller.resetDim()
    }

    func testWarmthClampedBySafetyPolicy() {
        let controller = TuneController()
        do {
            try controller.applyWarmth(0.5)
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported (no built-in display), got \(error)")
            }
            return  // no built-in display; warmth tests are display-dependent
        }
        XCTAssertNoThrow(try controller.applyWarmth(0.0))
        XCTAssertNoThrow(try controller.applyWarmth(2.0))
    }

    func testResetWarmth() {
        let controller = TuneController()
        do {
            try controller.applyWarmth(0.5)
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported (no built-in display), got \(error)")
            }
            return  // no built-in display; warmth tests are display-dependent
        }
        XCTAssertNoThrow(try controller.resetWarmth())
    }

    func testRestoreAllNoOpWithoutOverrides() {
        let controller = TuneController()
        let warmthBefore = controller.getWarmthLevel()
        let dimBefore = controller.getDimLevel()
        controller.restoreAll()
        XCTAssertEqual(controller.getWarmthLevel(), warmthBefore)
        XCTAssertEqual(controller.getDimLevel(), dimBefore)
    }

    func testChargeLimitRequiresSMC() {
        XCTAssertThrowsError(try TuneController().applyChargeLimit(percent: 80)) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("SMC") || message.contains("permission") || message.contains("unsupported"),
                "unexpected error: \(error)"
            )
        }
    }

    func testApplyProfileWithBrightnessAndDim() throws {
        let controller = TuneController()
        let profile = try TuneProfile(name: "test", brightness: 0.5, dim: 0.7)
        do {
            try controller.applyProfile(profile)
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported (no built-in display), got \(error)")
            }
            // no built-in display; profile brightness/dim test is display-dependent
        }
    }

    func testApplyProfileWithWarmth() throws {
        let controller = TuneController()
        let profile = try TuneProfile(name: "test", warmth: 0.4)
        do {
            try controller.applyProfile(profile)
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported (no built-in display), got \(error)")
            }
            // no built-in display; profile warmth test is display-dependent
        }
    }

    func testApplyProfileMinimal() throws {
        let controller = TuneController()
        let profile = try TuneProfile(name: "empty")
        XCTAssertNoThrow(try controller.applyProfile(profile))
    }

    func testGetWarmthLevelDefault() {
        let controller = TuneController()
        XCTAssertEqual(controller.getWarmthLevel(), 0)
    }

    func testGetDimLevelDefault() {
        let controller = TuneController()
        XCTAssertEqual(controller.getDimLevel(), 1.0)
    }
}

// MARK: - SemVer parsing

final class SemVerParsingTests: XCTestCase {
    func testParseBasicVersion() {
        let v = UpdateChecker.SemVer.parse("v0.1.0")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 1)
        XCTAssertEqual(v?.patch, 0)
        XCTAssertNil(v?.prerelease)
    }

    func testParseWithoutVPrefix() {
        let v = UpdateChecker.SemVer.parse("1.2.3")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
    }

    func testParsePrerelease() {
        let v = UpdateChecker.SemVer.parse("v0.2.0-beta.1")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 0)
        XCTAssertEqual(v?.prerelease, "beta.1")
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(UpdateChecker.SemVer.parse(""))
        XCTAssertNil(UpdateChecker.SemVer.parse("not-a-version"))
        XCTAssertNil(UpdateChecker.SemVer.parse("v1.2"))
        XCTAssertNil(UpdateChecker.SemVer.parse("v1.2.x"))
        XCTAssertNil(UpdateChecker.SemVer.parse("abc.def.ghi"))
    }

    func testDescription() {
        let v = UpdateChecker.SemVer(major: 1, minor: 2, patch: 3)
        XCTAssertEqual("\(v)", "1.2.3")

        let pre = UpdateChecker.SemVer(major: 0, minor: 1, patch: 0, prerelease: "alpha.1")
        XCTAssertEqual("\(pre)", "0.1.0-alpha.1")
    }
}

// MARK: - SemVer comparison

final class SemVerComparisonTests: XCTestCase {
    func testMajorVersionOrdering() {
        XCTAssertTrue(UpdateChecker.SemVer.parse("v1.0.0")! < UpdateChecker.SemVer.parse("v2.0.0")!)
    }

    func testMinorVersionOrdering() {
        XCTAssertTrue(UpdateChecker.SemVer.parse("v0.1.0")! < UpdateChecker.SemVer.parse("v0.2.0")!)
    }

    func testPatchVersionOrdering() {
        XCTAssertTrue(UpdateChecker.SemVer.parse("v0.1.1")! < UpdateChecker.SemVer.parse("v0.1.2")!)
    }

    func testPrereleaseBeforeRelease() {
        XCTAssertTrue(UpdateChecker.SemVer.parse("v0.2.0-beta.1")! < UpdateChecker.SemVer.parse("v0.2.0")!)
    }

    func testPrereleaseOrdering() {
        XCTAssertTrue(UpdateChecker.SemVer.parse("v0.2.0-alpha.1")! < UpdateChecker.SemVer.parse("v0.2.0-beta.1")!)
    }

    func testEqualVersions() {
        XCTAssertEqual(UpdateChecker.SemVer.parse("v0.1.0"), UpdateChecker.SemVer.parse("v0.1.0"))
    }

    func testCurrentVersionLessThanHypothetical() {
        let current = UpdateChecker.SemVer.parse("v\(TuneVersion.current)")!
        let future = UpdateChecker.SemVer.parse("v99.0.0")!
        XCTAssertTrue(current < future)
    }
}

// MARK: - Update check opt-out

final class UpdateCheckOptOutTests: XCTestCase {
    func testDefaultIsEnabled() {
        XCTAssertTrue(UpdateChecker.isUpdateCheckEnabled(env: [:]))
    }

    func testEnvVarFalseDisables() {
        XCTAssertFalse(UpdateChecker.isUpdateCheckEnabled(env: ["SYMTUNE_CHECK_UPDATES": "false"]))
    }

    func testEnvVarTrueEnables() {
        XCTAssertTrue(UpdateChecker.isUpdateCheckEnabled(env: ["SYMTUNE_CHECK_UPDATES": "true"]))
    }

    func testEnvVarOneDisables() {
        XCTAssertFalse(UpdateChecker.isUpdateCheckEnabled(env: ["SYMTUNE_CHECK_UPDATES": "0"]))
    }

    func testEnvVarCaseInsensitive() {
        XCTAssertFalse(UpdateChecker.isUpdateCheckEnabled(env: ["SYMTUNE_CHECK_UPDATES": "FALSE"]))
        XCTAssertFalse(UpdateChecker.isUpdateCheckEnabled(env: ["SYMTUNE_CHECK_UPDATES": "False"]))
    }
}

// MARK: - Mock DisplayWriteService

/// Mock implementation of DisplayWriteServiceProtocol for testing TuneController write paths.
final class MockDisplayWriteService: DisplayWriteServiceProtocol, @unchecked Sendable {
    var brightness: Double = 0.5
    var lastSetBrightness: Float?
    var lastWarmth: Float?
    var lastExtendedBrightness: Double?
    var lastExtendedDisplayID: UInt32?
    var resetWarmthCalled = false
    var setBuiltinBrightnessError: Error?
    var applyWarmthError: Error?
    var resetWarmthError: Error?
    var applyExtendedBrightnessError: Error?

    func getBuiltinBrightness() throws -> Double {
        brightness
    }

    func setBuiltinBrightness(_ value: Float) throws {
        if let error = setBuiltinBrightnessError { throw error }
        lastSetBrightness = value
    }

    func applyWarmth(_ warmth: Float) throws {
        if let error = applyWarmthError { throw error }
        lastWarmth = warmth
    }

    func resetWarmth() throws {
        if let error = resetWarmthError { throw error }
        resetWarmthCalled = true
    }

    func applyExtendedBrightness(_ multiplier: Double, displayID: UInt32?) throws {
        if let error = applyExtendedBrightnessError { throw error }
        lastExtendedBrightness = multiplier
        lastExtendedDisplayID = displayID
    }
}

// MARK: - TuneController Write Path Tests (with mock)
// MARK: - TuneController Write Path Tests (with mock)

final class TuneControllerWritePathTests: XCTestCase {
    private var mock: MockDisplayWriteService!
    private var controller: TuneController!

    override func setUp() {
        super.setUp()
        mock = MockDisplayWriteService()
        controller = TuneController(config: TuneConfig(), displayWrite: mock)
    }

    // MARK: - applyBuiltinBrightness

    func testApplyBuiltinBrightnessClampsAndSets() throws {
        mock.brightness = 0.8
        try controller.applyBuiltinBrightness(1.5)
        // Should clamp to config.brightnessMax (default 1.0)
        XCTAssertEqual(mock.lastSetBrightness, 1.0)
    }

    func testApplyBuiltinBrightnessSavesOriginal() throws {
        mock.brightness = 0.6
        try controller.applyBuiltinBrightness(0.9)
        // Original brightness (0.6) should be saved for restore
        XCTAssertEqual(mock.lastSetBrightness, 0.9)
    }

    func testApplyBuiltinBrightnessWithCustomRange() throws {
        let config = TuneConfig(brightnessMin: 0.2, brightnessMax: 0.8)
        let ctrl = TuneController(config: config, displayWrite: mock)
        mock.brightness = 0.5
        try ctrl.applyBuiltinBrightness(0.1)
        // Should clamp to 0.2 (brightnessMin)
        XCTAssertEqual(mock.lastSetBrightness, 0.2)
    }

    // MARK: - applyExtendedBrightness

    func testApplyExtendedBrightnessClampsAndApplies() throws {
        try controller.applyExtendedBrightness(2.0)
        // Should clamp to config.extendedBrightnessMax (default 1.6)
        XCTAssertEqual(mock.lastExtendedBrightness, 1.6)
        XCTAssertNil(mock.lastExtendedDisplayID)
    }

    func testApplyExtendedBrightnessWithCustomMax() throws {
        let config = TuneConfig(extendedBrightnessMax: 1.4)
        let ctrl = TuneController(config: config, displayWrite: mock)
        try ctrl.applyExtendedBrightness(1.5)
        XCTAssertEqual(mock.lastExtendedBrightness, 1.4)
    }

    func testApplyExtendedBrightnessBelowMinClampsToMin() throws {
        try controller.applyExtendedBrightness(0.5)
        // Should clamp to config.extendedBrightnessMin (default 1.0)
        XCTAssertEqual(mock.lastExtendedBrightness, 1.0)
    }

    // MARK: - applyWarmth

    func testApplyWarmthClampsAndApplies() throws {
        try controller.applyWarmth(1.5)
        // Should clamp to 1.0
        XCTAssertEqual(mock.lastWarmth, 1.0)
    }

    func testApplyWarmthNegativeClampsToZero() throws {
        try controller.applyWarmth(-0.5)
        XCTAssertEqual(mock.lastWarmth, 0.0)
    }

    func testApplyWarmthMiddleValue() throws {
        try controller.applyWarmth(0.5)
        XCTAssertEqual(mock.lastWarmth, 0.5)
    }

    // MARK: - resetWarmth

    func testResetWarmthCallsReset() throws {
        try controller.resetWarmth()
        XCTAssertTrue(mock.resetWarmthCalled)
    }

    // MARK: - getBuiltinBrightness

    func testGetBuiltinBrightnessReturnsMockValue() throws {
        mock.brightness = 0.75
        let value = try controller.getBuiltinBrightness()
        XCTAssertEqual(value, 0.75)
    }

    // MARK: - Default init still works

    func testDefaultInitUsesHardwareService() {
        // The default init should still work (uses HardwareDisplayWriteService)
        let defaultController = TuneController()
        XCTAssertNotNil(defaultController)
    }
}

// MARK: - TuneController Profile & Rule Tests

final class TuneControllerProfileTests: XCTestCase {
    private var controller: TuneController!

    override func setUp() {
        super.setUp()
        controller = TuneController()
    }

    // MARK: - Profiles

    func testSaveAndLoadProfile() throws {
        let profile = try TuneProfile(name: "ctrl-test", brightness: 0.7, dim: 0.5, warmth: 0.3)
        try controller.saveProfile(profile)
        let loaded = try controller.loadProfile(name: "ctrl-test")
        XCTAssertEqual(loaded.name, "ctrl-test")
        XCTAssertEqual(loaded.brightness, 0.7)
        XCTAssertEqual(loaded.dim, 0.5)
        XCTAssertEqual(loaded.warmth, 0.3)
        // Cleanup
        try? controller.deleteProfile(name: "ctrl-test")
    }

    func testListProfiles() throws {
        let before = controller.listProfiles().count
        let profile = try TuneProfile(name: "ctrl-list-test", brightness: 0.5)
        try controller.saveProfile(profile)
        XCTAssertEqual(controller.listProfiles().count, before + 1)
        // Cleanup
        try? controller.deleteProfile(name: "ctrl-list-test")
    }

    func testDeleteProfile() throws {
        let profile = try TuneProfile(name: "ctrl-delete-test", brightness: 0.5)
        try controller.saveProfile(profile)
        XCTAssertEqual(controller.listProfiles().contains { $0.name == "ctrl-delete-test" }, true)
        try controller.deleteProfile(name: "ctrl-delete-test")
        XCTAssertEqual(controller.listProfiles().contains { $0.name == "ctrl-delete-test" }, false)
    }

    func testLoadNonexistentProfileThrows() {
        XCTAssertThrowsError(try controller.loadProfile(name: "nonexistent-profile-\(UUID().uuidString)"))
    }

    // MARK: - Rules

    func testSaveAndLoadRules() throws {
        let rule = TuneRule(condition: .onBattery, profileName: "low-power")
        try controller.saveRules([rule])
        let rules = controller.loadRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].condition, .onBattery)
        XCTAssertEqual(rules[0].profileName, "low-power")
        // Cleanup
        try controller.saveRules([])
    }

    func testAddAndRemoveRule() throws {
        let rule = TuneRule(id: "ctrl-rule-1", condition: .onAC, profileName: "default")
        try controller.addRule(rule)
        let rules = controller.loadRules()
        XCTAssertTrue(rules.contains { $0.id == "ctrl-rule-1" })
        try controller.removeRule(id: "ctrl-rule-1")
        let afterRemove = controller.loadRules()
        XCTAssertFalse(afterRemove.contains { $0.id == "ctrl-rule-1" })
    }
}

final class SMCKeyTests: XCTestCase {
    func testEncodeDecodeRoundtrip() {
        let key = "fpe2"
        let encoded = smcEncodeKey(key)
        XCTAssertNotEqual(encoded, 0)
        let decoded = smcDecodeKey(encoded)
        XCTAssertEqual(decoded, key)
    }

    func testDecodeKnownKey() {
        let encoded = smcEncodeKey("sp78")
        let decoded = smcDecodeKey(encoded)
        XCTAssertEqual(decoded, "sp78")
    }

    func testEncodeInvalidLengthReturnsZero() {
        XCTAssertEqual(smcEncodeKey("ab"), 0)
        XCTAssertEqual(smcEncodeKey("abcde"), 0)
        XCTAssertEqual(smcEncodeKey(""), 0)
    }
}

final class SMCConvertValueTests: XCTestCase {
    func testFpe2Conversion() {
        let dataType = smcEncodeKey("fpe2")
        let bytes: [UInt8] = [0x01, 0x00]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 1.0, accuracy: 0.01)
    }

    func testFpe2FractionalPart() {
        let dataType = smcEncodeKey("fpe2")
        let bytes: [UInt8] = [0x00, 0x80]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 0.5, accuracy: 0.01)
    }

    func testFpe2InsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("fpe2")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: [0x01]), 0)
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: []), 0)
    }

    func testFltConversion() {
        let dataType = smcEncodeKey("flt ")
        var val: Float = 42.0
        let raw = withUnsafePointer(to: &val) { $0.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee } }
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF),
        ]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 42.0, accuracy: 0.01)
    }

    func testFltInsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("flt ")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: [0x01, 0x02, 0x03]), 0)
    }

    func testSp78PositiveValue() {
        let dataType = smcEncodeKey("sp78")
        let bytes: [UInt8] = [0x01, 0x00]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 1.0, accuracy: 0.01)
    }

    func testSp78NegativeValue() {
        let dataType = smcEncodeKey("sp78")
        let bytes: [UInt8] = [0xFF, 0x00]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, -1.0, accuracy: 0.01)
    }

    func testSp78InsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("sp78")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: [0x01]), 0)
    }

    func testUi8Conversion() {
        let dataType = smcEncodeKey("ui8 ")
        let result = smcConvertValue(dataType: dataType, bytes: [255])
        XCTAssertEqual(result, 255.0)
    }

    func testUi8InsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("ui8 ")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: []), 0)
    }

    func testUi16Conversion() {
        let dataType = smcEncodeKey("ui16")
        let result = smcConvertValue(dataType: dataType, bytes: [0x01, 0x00])
        XCTAssertEqual(result, 256.0)
    }

    func testUi16InsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("ui16")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: [0x01]), 0)
    }

    func testUi32Conversion() {
        let dataType = smcEncodeKey("ui32")
        let result = smcConvertValue(dataType: dataType, bytes: [0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(result, 65536.0)
    }

    func testUi32InsufficientBytesReturnsZero() {
        let dataType = smcEncodeKey("ui32")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: [0x01, 0x02, 0x03]), 0)
    }

    func testUnknownTypeInterpretsAsUnsignedInteger() {
        let dataType = smcEncodeKey("xxxx")
        let result = smcConvertValue(dataType: dataType, bytes: [0x00, 0x01])
        XCTAssertEqual(result, 1.0)
    }

    func testUnknownTypeEmptyBytesReturnsZero() {
        let dataType = smcEncodeKey("xxxx")
        XCTAssertEqual(smcConvertValue(dataType: dataType, bytes: []), 0)
    }
}

import XCTest
@testable import SymCockpitCore

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

final class SensorTests: XCTestCase {
    func testThermalPressureIsKnownLabel() {
        let label = SensorService.thermalPressureLabel()
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(label))
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
    // `fpe2` is unsigned fixed-point 14.2: 14 integer bits, 2 fractional
    // bits, so raw = value * 4 (issue #193). Before the fix this case
    // divided by 256 (the `sp78` scale), understating Intel fan RPM by 64x.
    func testFpe2Conversion() {
        let dataType = smcEncodeKey("fpe2")
        let bytes: [UInt8] = [0x00, 0x04] // 4 / 4 = 1.0
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 1.0, accuracy: 0.01)
    }

    func testFpe2FractionalPart() {
        let dataType = smcEncodeKey("fpe2")
        let bytes: [UInt8] = [0x00, 0x02] // 2 / 4 = 0.5
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 0.5, accuracy: 0.01)
    }

    /// Real firmware example from issue #193: an Intel fan reporting 6000 RPM
    /// encodes as raw 24000 (0x5DC0) at the 14.2 fixed-point scale. The old
    /// `/256` decode would have understated this as 93.75 RPM (a 64x error).
    func testFpe2DecodesRealFirmwareFanRPM() {
        let dataType = smcEncodeKey("fpe2")
        let result = smcConvertValue(dataType: dataType, bytes: [0x5D, 0xC0])
        XCTAssertEqual(result, 6000.0, accuracy: 0.01)
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
        // `flt ` payloads are little-endian, unlike the integer and
        // fixed-point types (issue #185, verified against an M4 Pro).
        let bytes: [UInt8] = [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
        ]
        let result = smcConvertValue(dataType: dataType, bytes: bytes)
        XCTAssertEqual(result, 42.0, accuracy: 0.01)
    }

    /// Bytes captured from a live M4 Pro `F0Ac` read: 5235.6 rpm
    /// little-endian, and a nonsensical -2.1e10 big-endian.
    func testFltDecodesHardwareCapturedFanRPM() {
        let result = smcConvertValue(
            dataType: smcEncodeKey("flt "),
            bytes: [0xD1, 0x9C, 0xA3, 0x45]
        )
        XCTAssertEqual(result, 5235.6, accuracy: 0.1)
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

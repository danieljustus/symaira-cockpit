import XCTest
@testable import SymTuneCore

/// Collects the delays the fan retry loop asks for, so tests can assert the
/// backoff policy without actually waiting.
private final class RecordedDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        lock.lock()
        storage.append(delay)
        lock.unlock()
    }

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class FanControlServiceTests: XCTestCase {
    #if arch(arm64)
    private func makeAppleSiliconFanKeys(targetRPM: Double = 10, maxRPM: Double = 100, mode: UInt8 = 3) -> [String: FakeSMCKeyResult] {
        let flt = smcEncodeKey("flt ")
        let ui8 = smcEncodeKey("ui8 ")
        return [
            "FNum": FakeSMCKeyResult(dataType: ui8, bytes: [1]),
            "F0Ac": FakeSMCKeyResult(dataType: flt, bytes: floatBytes(targetRPM)),
            "F0Tg": FakeSMCKeyResult(dataType: flt, bytes: floatBytes(targetRPM)),
            "F0Mx": FakeSMCKeyResult(dataType: flt, bytes: floatBytes(maxRPM)),
            "F0Mn": FakeSMCKeyResult(dataType: flt, bytes: floatBytes(5)),
            "F0Md": FakeSMCKeyResult(dataType: ui8, bytes: [mode]),
            "Ftst": FakeSMCKeyResult(dataType: ui8, bytes: [0]),
        ]
    }
    #endif

    #if arch(x86_64)
    private func makeIntelFanKeys(targetRPM: Double = 10, maxRPM: Double = 100, mode: UInt8 = 3) -> [String: FakeSMCKeyResult] {
        let fpe2 = smcEncodeKey("fpe2")
        let ui8 = smcEncodeKey("ui8 ")
        return [
            "FNum": FakeSMCKeyResult(dataType: ui8, bytes: [1]),
            "F0Ac": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(targetRPM)),
            "F0Tg": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(targetRPM)),
            "F0Mx": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(maxRPM)),
            "F0Mn": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(5)),
            "F0Md": FakeSMCKeyResult(dataType: ui8, bytes: [mode]),
            "FS!": FakeSMCKeyResult(dataType: smcEncodeKey("ui16"), bytes: [0, 0]),
        ]
    }
    #endif

    private func floatBytes(_ value: Double) -> [UInt8] {
        let raw = Float(value).bitPattern
        return [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
    }

    private func fpe2Bytes(_ value: Double) -> [UInt8] {
        let raw = UInt16((value * 256).rounded())
        return [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
    }

    #if arch(arm64)
    func testAppleSiliconSetFanWritesTargetRPM() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: makeAppleSiliconFanKeys())
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        try service.applyFan(fraction: 0.5, config: TuneConfig())

        let target = conn.writtenKeys.first { $0.key == "F0Tg" }
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.dataType, smcEncodeKey("flt "))
        XCTAssertEqual(target?.bytes, floatBytes(50))
    }

    func testAppleSiliconRestoreAutoClearsFtstAndMode() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: makeAppleSiliconFanKeys())
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        try service.applyFan(fraction: 0.5, config: TuneConfig())
        try service.restoreAuto()

        let mode = conn.writtenKeys.first { $0.key == "F0Md" && $0.bytes == [3] }
        XCTAssertNotNil(mode)
        let ftst = conn.writtenKeys.last { $0.key == "Ftst" }
        XCTAssertEqual(ftst?.bytes, [0])
    }
    #endif

    #if arch(x86_64)
    func testIntelSetFanWritesTargetRPM() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: makeIntelFanKeys())
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        try service.applyFan(fraction: 0.5, config: TuneConfig())

        let target = conn.writtenKeys.first { $0.key == "F0Tg" }
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.dataType, smcEncodeKey("fpe2"))
        XCTAssertEqual(target?.bytes, fpe2Bytes(50))
    }

    func testIntelRestoreAutoWritesOriginalFSBitmask() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: makeIntelFanKeys())
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        try service.applyFan(fraction: 0.5, config: TuneConfig())
        try service.restoreAuto()

        let fs = conn.writtenKeys.last { $0.key == "FS!" }
        XCTAssertEqual(fs?.bytes, [0, 0])
    }
    #endif

    func testRestoreAutoThrowsOnNoFans() {
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "FNum": FakeSMCKeyResult(dataType: smcEncodeKey("ui8 "), bytes: [0]),
        ])
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.restoreAuto()) { error in
            guard let fanError = error as? FanControlError else {
                XCTFail("Expected FanControlError, got \(type(of: error))")
                return
            }
            switch fanError {
            case .noFansDetected: break
            default: XCTFail("Expected noFansDetected, got \(fanError)")
            }
        }
    }

    func testFanControlRefusesWhenSMCUnavailable() {
        let conn = FakeSMCConnection(isOpen: false)
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            XCTAssertTrue("\(error)".contains("SMC"))
        }
    }

    #if arch(arm64)
    func testFanControlRefusesThermalEmergency() {
        var keys = makeAppleSiliconFanKeys()
        let flt = smcEncodeKey("flt ")
        keys["Ts0S"] = FakeSMCKeyResult(dataType: flt, bytes: floatBytes(95)) // above 90 threshold
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            XCTAssertTrue("\(error)".contains("thermal"))
        }
    }

    func testAppleSiliconFanControlRetriesAndFailsOnManualMode() {
        let keys = makeAppleSiliconFanKeys(mode: 3)
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.writeHandler = { _, _, _ in true }
        let delays = RecordedDelays()
        let smc = SMCService(connection: conn)
        let service = FanControlService(
            smc: smc,
            sensors: SensorService(smc: smc),
            sleep: { delays.record($0) }
        )

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            guard let fanError = error as? FanControlError else {
                XCTFail("Expected FanControlError")
                return
            }
            switch fanError {
            case .fanModeWriteRejected(let idx):
                XCTAssertEqual(idx, 0)
                XCTAssertEqual(
                    delays.values,
                    [0.05, 0.1, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2],
                    "Expected 10 attempts with the 50 ms → 200 ms backoff between them"
                )
            default:
                XCTFail("Expected fanModeWriteRejected error")
            }
        }
    }

    func testAppleSiliconFanControlFailsOnTargetRPMWrite() {
        let keys = makeAppleSiliconFanKeys()
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.writeHandler = { key, dataType, bytes in
            if key == "F0Tg" {
                return false
            }
            if key == "F0Md" {
                conn.keys["F0Md"] = FakeSMCKeyResult(dataType: dataType, bytes: bytes)
            }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            guard let fanError = error as? FanControlError else {
                XCTFail("Expected FanControlError")
                return
            }
            switch fanError {
            case .targetRPMWriteFailed(let idx):
                XCTAssertEqual(idx, 0)
            default:
                XCTFail("Expected targetRPMWriteFailed error")
            }
        }
    }
    #endif

    #if arch(x86_64)
    func testIntelFanControlFailsOnTargetRPMWrite() {
        let keys = makeIntelFanKeys()
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.writeHandler = { key, _, _ in
            if key == "F0Tg" {
                return false
            }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            guard let fanError = error as? FanControlError else {
                XCTFail("Expected FanControlError")
                return
            }
            switch fanError {
            case .targetRPMWriteFailed(let idx):
                XCTAssertEqual(idx, 0)
            default:
                XCTFail("Expected targetRPMWriteFailed error")
            }
        }
    }

    func testIntelFanControlFailsOnFSWrite() {
        let keys = makeIntelFanKeys()
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.writeHandler = { key, _, _ in
            if key == "FS!" {
                return false
            }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = FanControlService(smc: smc, sensors: SensorService(smc: smc))

        XCTAssertThrowsError(try service.applyFan(fraction: 0.5, config: TuneConfig())) { error in
            guard let fanError = error as? FanControlError else {
                XCTFail("Expected FanControlError")
                return
            }
            switch fanError {
            case .targetRPMWriteFailed(let idx):
                XCTAssertEqual(idx, 0)
            default:
                XCTFail("Expected targetRPMWriteFailed error")
            }
        }
    }
    #endif

    func testFanPresetProperties() {
        XCTAssertEqual(FanPreset.quiet.displayName, "Quiet")
        XCTAssertEqual(FanPreset.auto.displayName, "Auto")
        XCTAssertEqual(FanPreset.cool.displayName, "Cool")

        XCTAssertEqual(FanPreset.quiet.fanFraction, 0.15)
        XCTAssertEqual(FanPreset.auto.fanFraction, 0.5)
        XCTAssertEqual(FanPreset.cool.fanFraction, 0.85)
    }

    func testFanCurvePointsAndFraction() {
        let p1 = FanCurvePoint(temperatureC: 40, fraction: 0.1)
        let p2 = FanCurvePoint(temperatureC: 60, fraction: 0.3)
        let curve = FanCurve(name: "Test", points: [p2, p1])

        XCTAssertEqual(curve.points[0].temperatureC, 40)
        XCTAssertEqual(curve.points[1].temperatureC, 60)

        XCTAssertEqual(curve.fraction(at: 30), 0.1)
        XCTAssertEqual(curve.fraction(at: 40), 0.1)
        XCTAssertEqual(curve.fraction(at: 50), 0.2)
        XCTAssertEqual(curve.fraction(at: 60), 0.3)
        XCTAssertEqual(curve.fraction(at: 70), 0.3)

        let emptyCurve = FanCurve(name: "Empty", points: [])
        XCTAssertEqual(emptyCurve.fraction(at: 50), 0.0)
    }

    func testFanControlErrorDescriptions() {
        XCTAssertEqual("\(FanControlError.noFansDetected)", "no fans detected")
        XCTAssertEqual("\(FanControlError.fanModeWriteRejected(1))", "fan 1 rejected manual mode")
        XCTAssertEqual("\(FanControlError.targetRPMWriteFailed(2))", "fan 2 target RPM write failed")
        XCTAssertEqual("\(FanControlError.unsupportedPlatform)", "unsupported platform")
    }
}

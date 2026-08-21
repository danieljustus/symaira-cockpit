import XCTest
@testable import SymTuneCore

final class SMCWritePolicyTests: XCTestCase {
    // Helper to generate Float bytes for SMC
    private func floatBytes(_ value: Double) -> [UInt8] {
        let raw = Float(value).bitPattern
        return [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
    }

    // Helper to generate fpe2 bytes for SMC
    private func fpe2Bytes(_ value: Double) -> [UInt8] {
        let raw = UInt16((value * 256).rounded())
        return [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
    }

    func testValidationErrorDescriptions() {
        XCTAssertEqual(SMCWritePolicy.ValidationError.noSMCConnection.description, "SMC connection unavailable")
        XCTAssertEqual(SMCWritePolicy.ValidationError.thermalEmergency(92.5).description, "thermal emergency: sensor at 92.5°C; refusing fan write")
        XCTAssertEqual(SMCWritePolicy.ValidationError.fanMaxRPMUnavailable(1).description, "fan 1 maximum RPM unavailable")
        XCTAssertEqual(SMCWritePolicy.ValidationError.chargeLimitNoACPower.description, "charge limit requires AC power")
    }

    func testClampFanFraction() {
        // SafetyPolicy.fanSpeedFloor is 0.15, min fanFractionMin is 0.0, max fanFractionMax is 1.0
        XCTAssertEqual(SMCWritePolicy.clampFanFraction(0.5, min: 0.0, max: 1.0), 0.5)
        XCTAssertEqual(SMCWritePolicy.clampFanFraction(0.05, min: 0.0, max: 1.0), 0.15) // floor
        XCTAssertEqual(SMCWritePolicy.clampFanFraction(-0.1, min: 0.0, max: 1.0), 0.15) // clamped & floored
        XCTAssertEqual(SMCWritePolicy.clampFanFraction(1.5, min: 0.0, max: 1.0), 1.0)  // clamped
    }

    func testTargetRPMThrowsOnSMCUnavailable() {
        let conn = FakeSMCConnection(isOpen: false)
        let smc = SMCService(connection: conn)
        XCTAssertThrowsError(try SMCWritePolicy.targetRPM(fraction: 0.5, fanIndex: 0, smc: smc)) { error in
            guard let validationError = error as? SMCWritePolicy.ValidationError else {
                return XCTFail("expected SMCWritePolicy.ValidationError, got \(error)")
            }
            if case .noSMCConnection = validationError {
                // Success
            } else {
                XCTFail("expected .noSMCConnection, got \(validationError)")
            }
        }
    }

    func testTargetRPMThrowsOnFanMaxRPMUnavailable() {
        let conn = FakeSMCConnection(isOpen: true, keys: [:])
        let smc = SMCService(connection: conn)
        XCTAssertThrowsError(try SMCWritePolicy.targetRPM(fraction: 0.5, fanIndex: 0, smc: smc)) { error in
            guard let validationError = error as? SMCWritePolicy.ValidationError else {
                return XCTFail("expected SMCWritePolicy.ValidationError, got \(error)")
            }
            if case .fanMaxRPMUnavailable(let index) = validationError {
                XCTAssertEqual(index, 0)
            } else {
                XCTFail("expected .fanMaxRPMUnavailable, got \(validationError)")
            }
        }

        // Also test when maxRPM is <= 0
        let fpe2 = smcEncodeKey("fpe2")
        let connZero = FakeSMCConnection(isOpen: true, keys: [
            "F0Mx": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(0.0))
        ])
        let smcZero = SMCService(connection: connZero)
        XCTAssertThrowsError(try SMCWritePolicy.targetRPM(fraction: 0.5, fanIndex: 0, smc: smcZero)) { error in
            guard let validationError = error as? SMCWritePolicy.ValidationError else {
                return XCTFail("expected SMCWritePolicy.ValidationError, got \(error)")
            }
            if case .fanMaxRPMUnavailable(let index) = validationError {
                XCTAssertEqual(index, 0)
            } else {
                XCTFail("expected .fanMaxRPMUnavailable, got \(validationError)")
            }
        }
    }

    func testTargetRPMReturnsExpectedValues() throws {
        let fpe2 = smcEncodeKey("fpe2")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "F0Mx": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(100.0)),
            "F0Mn": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(20.0))
        ])
        let smc = SMCService(connection: conn)

        // 0.5 * 100 = 50, which is > 20
        let target = try SMCWritePolicy.targetRPM(fraction: 0.5, fanIndex: 0, smc: smc)
        XCTAssertEqual(target, 50.0, accuracy: 0.01)

        // 0.1 * 100 = 10, floored to minRPM (20)
        let flooredTarget = try SMCWritePolicy.targetRPM(fraction: 0.1, fanIndex: 0, smc: smc)
        XCTAssertEqual(flooredTarget, 20.0, accuracy: 0.01)
    }

    func testRequireThermalHeadroom() throws {
        #if arch(arm64)
        let tempKey = "Tp01"
        let dataType = smcEncodeKey("flt ")
        let highTempBytes = floatBytes(95.0)
        let lowTempBytes = floatBytes(45.0)
        #else
        let tempKey = "TC0C"
        let dataType = smcEncodeKey("fpe2")
        let highTempBytes = fpe2Bytes(95.0)
        let lowTempBytes = fpe2Bytes(45.0)
        #endif

        // Cool temperature -> no throw
        let connCool = FakeSMCConnection(isOpen: true, keys: [
            tempKey: FakeSMCKeyResult(dataType: dataType, bytes: lowTempBytes)
        ])
        let sensorsCool = SensorService(smc: SMCService(connection: connCool))
        XCTAssertNoThrow(try SMCWritePolicy.requireThermalHeadroom(sensors: sensorsCool))

        // Hot temperature -> throws thermalEmergency
        let connHot = FakeSMCConnection(isOpen: true, keys: [
            tempKey: FakeSMCKeyResult(dataType: dataType, bytes: highTempBytes)
        ])
        let sensorsHot = SensorService(smc: SMCService(connection: connHot))
        XCTAssertThrowsError(try SMCWritePolicy.requireThermalHeadroom(sensors: sensorsHot)) { error in
            guard let validationError = error as? SMCWritePolicy.ValidationError else {
                return XCTFail("expected SMCWritePolicy.ValidationError, got \(error)")
            }
            if case .thermalEmergency(let celsius) = validationError {
                XCTAssertEqual(celsius, 95.0, accuracy: 0.01)
            } else {
                XCTFail("expected .thermalEmergency, got \(validationError)")
            }
        }
    }

    func testRequireACPower() throws {
        // 1. External connected true -> passes
        let propsAC = BatteryProperties(
            isCharging: true,
            externalConnected: true,
            rawMaxCapacity: 100,
            rawCurrentCapacity: 50
        )
        let sourceAC = FakeBatterySource(result: .success(propsAC))
        let batteryAC = BatteryService(source: sourceAC)
        XCTAssertNoThrow(try SMCWritePolicy.requireACPower(battery: batteryAC))

        // 2. External connected false -> throws chargeLimitNoACPower
        let propsBattery = BatteryProperties(
            isCharging: false,
            externalConnected: false,
            rawMaxCapacity: 100,
            rawCurrentCapacity: 50
        )
        let sourceBattery = FakeBatterySource(result: .success(propsBattery))
        let batteryBattery = BatteryService(source: sourceBattery)
        XCTAssertThrowsError(try SMCWritePolicy.requireACPower(battery: batteryBattery)) { error in
            guard let validationError = error as? SMCWritePolicy.ValidationError else {
                return XCTFail("expected SMCWritePolicy.ValidationError, got \(error)")
            }
            if case .chargeLimitNoACPower = validationError {
                // Success
            } else {
                XCTFail("expected .chargeLimitNoACPower, got \(validationError)")
            }
        }

        // 3. Battery not present -> passes
        let sourceNone = FakeBatterySource(result: .unavailable)
        let batteryNone = BatteryService(source: sourceNone)
        XCTAssertNoThrow(try SMCWritePolicy.requireACPower(battery: batteryNone))
    }

    func testSMCServiceFanHelperExtensions() {
        let fpe2 = smcEncodeKey("fpe2")
        let ui8 = smcEncodeKey("ui8 ")

        // Test with all keys present
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "F0Mn": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(10.0)),
            "F0Mx": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(100.0)),
            "F0Tg": FakeSMCKeyResult(dataType: fpe2, bytes: fpe2Bytes(50.0)),
            "F0Md": FakeSMCKeyResult(dataType: ui8, bytes: [1])
        ])
        let smc = SMCService(connection: conn)

        XCTAssertEqual(try XCTUnwrap(smc.readFanMinRPM(fanIndex: 0)), 10.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(smc.readFanMaxRPM(fanIndex: 0)), 100.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(smc.readFanTargetRPM(fanIndex: 0)), 50.0, accuracy: 0.01)
        XCTAssertEqual(smc.readFanMode(fanIndex: 0), 1)

        // Test fallback to lowercase "md" key (covers line 96)
        let connFallback = FakeSMCConnection(isOpen: true, keys: [
            "F0md": FakeSMCKeyResult(dataType: ui8, bytes: [3])
        ])
        let smcFallback = SMCService(connection: connFallback)
        XCTAssertEqual(smcFallback.readFanMode(fanIndex: 0), 3)

        // Test nil when neither Md nor md exists
        let connNil = FakeSMCConnection(isOpen: true, keys: [:])
        let smcNil = SMCService(connection: connNil)
        XCTAssertNil(smcNil.readFanMode(fanIndex: 0))
    }
}

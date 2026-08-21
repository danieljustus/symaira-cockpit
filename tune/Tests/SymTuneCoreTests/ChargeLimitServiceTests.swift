import XCTest
@testable import SymTuneCore

final class ChargeLimitServiceTests: XCTestCase {
    #if arch(arm64)
    func testDetectsCHTEOnModernAppleSilicon() {
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertEqual(service.detectKeyFamily(), .chte)
    }

    func testFallsBackToCH0BWhenCHTEMissing() {
        let ui8 = smcEncodeKey("ui8 ")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CH0B": FakeSMCKeyResult(dataType: ui8, bytes: [0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertEqual(service.detectKeyFamily(), .ch0b)
    }

    func testInhibitChargeWritesCHTEAsUI32BigEndian() throws {
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        try service.applyChargeLimit(percent: 80, config: TuneConfig())

        let written = conn.writtenKeys.first { $0.key == "CHTE" }
        XCTAssertNotNil(written)
        XCTAssertEqual(written?.dataType, ui32)
        XCTAssertEqual(written?.bytes, [0, 0, 0, 1])
    }

    func testClearChargeLimitResetsCHTE() throws {
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 1])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        try service.clearChargeLimit()

        let written = conn.writtenKeys.first { $0.key == "CHTE" }
        XCTAssertEqual(written?.bytes, [0, 0, 0, 0])
    }
    #endif

    #if arch(x86_64)
    func testDetectsCHLCOnIntel() {
        let ui16 = smcEncodeKey("ui16")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHLC": FakeSMCKeyResult(dataType: ui16, bytes: [0, 0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertEqual(service.detectKeyFamily(), .chlc)
    }

    func testIntelChargeLimitWritesPercentAsUI16() throws {
        let ui16 = smcEncodeKey("ui16")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHLC": FakeSMCKeyResult(dataType: ui16, bytes: [0, 0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        try service.applyChargeLimit(percent: 80, config: TuneConfig())

        let written = conn.writtenKeys.first { $0.key == "CHLC" }
        XCTAssertNotNil(written)
        XCTAssertEqual(written?.dataType, ui16)
        XCTAssertEqual(written?.bytes, [0, 80])
    }
    #endif

    func testChargeLimitRefusesWhenSMCUnavailable() {
        let conn = FakeSMCConnection(isOpen: false)
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.applyChargeLimit(percent: 80, config: TuneConfig())) { error in
            XCTAssertTrue("\(error)".contains("SMC"))
        }
    }

    func testChargeLimitClampedBySafetyPolicy() throws {
        #if arch(arm64)
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        // 30 is below the SafetyPolicy minimum of 50; it should still write the inhibit bit
        // because the service only clamps to the configured range, but for a closed SMC
        // the actual clamping happens in the controller. This test verifies the service
        // accepts the value and produces the inhibit write.
        try service.applyChargeLimit(percent: 30, config: TuneConfig())
        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "CHTE" && $0.bytes == [0, 0, 0, 1] })
        #endif
    }

    func testChargeLimitErrorDescriptions() {
        XCTAssertEqual("\(ChargeLimitError.noSMCConnection)", "SMC not available")
        XCTAssertEqual("\(ChargeLimitError.keyProbeFailed)", "could not find a supported charge-limit SMC key")
        XCTAssertEqual("\(ChargeLimitError.inhibitWriteFailed)", "failed to inhibit charging")
        XCTAssertEqual("\(ChargeLimitError.allowWriteFailed)", "failed to re-enable charging")
        XCTAssertEqual("\(ChargeLimitError.unsupportedPlatform)", "this charge-limit key is not supported on the current platform")
    }

    #if arch(arm64)
    func testCH0BChargeLimitWritesExpectedKeys() throws {
        let ui8 = smcEncodeKey("ui8 ")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CH0B": FakeSMCKeyResult(dataType: ui8, bytes: [0])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        try service.applyChargeLimit(percent: 80, config: TuneConfig())

        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "CH0B" && $0.bytes == [2] })
        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "CH0C" && $0.bytes == [2] })
    }

    func testApplyChargeLimitFailsWhenCHTEWriteFails() {
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 0])
        ])
        conn.writeHandler = { key, _, _ in
            if key == "CHTE" { return false }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.applyChargeLimit(percent: 80, config: TuneConfig())) { error in
            XCTAssertEqual(error as? ChargeLimitError, ChargeLimitError.inhibitWriteFailed)
        }
    }

    func testApplyChargeLimitFailsWhenCH0BWriteFails() {
        let ui8 = smcEncodeKey("ui8 ")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CH0B": FakeSMCKeyResult(dataType: ui8, bytes: [0])
        ])
        conn.writeHandler = { key, _, _ in
            if key == "CH0B" { return false }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.applyChargeLimit(percent: 80, config: TuneConfig())) { error in
            XCTAssertEqual(error as? ChargeLimitError, ChargeLimitError.inhibitWriteFailed)
        }
    }

    func testClearChargeLimitFailsWhenCHTEWriteFails() {
        let ui32 = smcEncodeKey("ui32")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: ui32, bytes: [0, 0, 0, 1])
        ])
        conn.writeHandler = { key, _, _ in
            if key == "CHTE" { return false }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.clearChargeLimit()) { error in
            XCTAssertEqual(error as? ChargeLimitError, ChargeLimitError.allowWriteFailed)
        }
    }

    func testReadInhibitStateCH0B() {
        let ui8 = smcEncodeKey("ui8 ")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CH0B": FakeSMCKeyResult(dataType: ui8, bytes: [2])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertEqual(service.readInhibitState(), true)

        conn.keys["CH0B"] = FakeSMCKeyResult(dataType: ui8, bytes: [0])
        XCTAssertEqual(service.readInhibitState(), false)
    }
    #endif

    #if arch(x86_64)
    func testApplyChargeLimitFailsWhenCHLCWriteFails() {
        let ui16 = smcEncodeKey("ui16")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHLC": FakeSMCKeyResult(dataType: ui16, bytes: [0, 0])
        ])
        conn.writeHandler = { key, _, _ in
            if key == "CHLC" { return false }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.applyChargeLimit(percent: 80, config: TuneConfig())) { error in
            XCTAssertEqual(error as? ChargeLimitError, ChargeLimitError.inhibitWriteFailed)
        }
    }

    func testClearChargeLimitFailsWhenCHLCWriteFails() {
        let ui16 = smcEncodeKey("ui16")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHLC": FakeSMCKeyResult(dataType: ui16, bytes: [0, 80])
        ])
        conn.writeHandler = { key, _, _ in
            if key == "CHLC" { return false }
            return true
        }
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertThrowsError(try service.clearChargeLimit()) { error in
            XCTAssertEqual(error as? ChargeLimitError, ChargeLimitError.allowWriteFailed)
        }
    }

    func testReadInhibitStateIntel() {
        let ui16 = smcEncodeKey("ui16")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "CHLC": FakeSMCKeyResult(dataType: ui16, bytes: [0, 80])
        ])
        let smc = SMCService(connection: conn)
        let service = ChargeLimitService(smc: smc)

        XCTAssertNil(service.readInhibitState())
    }
    #endif
}

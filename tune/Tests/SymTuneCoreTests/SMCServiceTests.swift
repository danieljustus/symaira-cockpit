import XCTest
@testable import SymTuneCore

final class SMCServiceTests: XCTestCase {
    func testUnavailableConnectionReturnsEmptyTemperatures() {
        let conn = FakeSMCConnection(isOpen: false)
        let service = SMCService(connection: conn)

        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.readTemperatures(), [])
        XCTAssertEqual(service.readFans(), [])
    }

    func testMissingTemperatureKeysReturnsEmpty() {
        let conn = FakeSMCConnection(isOpen: true, keys: [:])
        let service = SMCService(connection: conn)

        XCTAssertTrue(service.isAvailable)
        XCTAssertEqual(service.readTemperatures(), [])
    }

    func testTemperatureReadings() {
        let fpe2 = smcEncodeKey("fpe2")
        // 0x0100 / 256 = 1.0
        #if arch(arm64)
        let key = "Tp01"
        let label = "CPU Core 1"
        #else
        let key = "TC0C"
        let label = "CPU Core 1"
        #endif
        let conn = FakeSMCConnection(isOpen: true, keys: [
            key: FakeSMCKeyResult(dataType: fpe2, bytes: [0x01, 0x00])
        ])
        let service = SMCService(connection: conn)

        let readings = service.readTemperatures()
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.key, key)
        XCTAssertEqual(readings.first?.label, label)
        XCTAssertEqual(readings.first?.celsius ?? 0, 1.0, accuracy: 0.01)
    }

    func testFanCountZeroReturnsEmpty() {
        let ui8 = smcEncodeKey("ui8 ")
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "FNum": FakeSMCKeyResult(dataType: ui8, bytes: [0])
        ])
        let service = SMCService(connection: conn)

        XCTAssertEqual(service.readFans(), [])
    }

    func testFanReadings() {
        let ui8 = smcEncodeKey("ui8 ")
        let fpe2 = smcEncodeKey("fpe2")
        // 0x0500 / 256 = 5.0
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "FNum": FakeSMCKeyResult(dataType: ui8, bytes: [1]),
            "F0Ac": FakeSMCKeyResult(dataType: fpe2, bytes: [0x05, 0x00])
        ])
        let service = SMCService(connection: conn)

        let fans = service.readFans()
        XCTAssertEqual(fans.count, 1)
        XCTAssertEqual(fans.first?.index, 0)
        XCTAssertEqual(fans.first?.label, "Main Fan")
        XCTAssertEqual(fans.first?.rpm, 5)
    }

    func testWriteKeyValueEncodesAndDelegates() {
        let conn = FakeSMCConnection(isOpen: true)
        let service = SMCService(connection: conn)

        let success = service.writeKeyValue("F0Tg", value: 2.0, dataType: "fpe2")
        XCTAssertTrue(success)
        XCTAssertEqual(conn.writtenKeys.count, 1)
        let written = conn.writtenKeys.first!
        XCTAssertEqual(written.key, "F0Tg")
        XCTAssertEqual(written.bytes, [0x02, 0x00])
    }

    func testWriteKeyValueEncodesFloatBigEndian() {
        let conn = FakeSMCConnection(isOpen: true)
        let service = SMCService(connection: conn)

        let success = service.writeKeyValue("F0Tg", value: 42.0, dataType: "flt ")
        XCTAssertTrue(success)
        let written = conn.writtenKeys.first!
        XCTAssertEqual(written.key, "F0Tg")
        XCTAssertEqual(written.dataType, smcEncodeKey("flt "))

        let val: Float = 42.0
        let raw = val.bitPattern
        let expected = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
        XCTAssertEqual(written.bytes, expected)
    }

    func testWriteKeyValueEncodesUInt32BigEndian() {
        let conn = FakeSMCConnection(isOpen: true)
        let service = SMCService(connection: conn)

        let success = service.writeKeyValue("CHTE", value: 1, dataType: "ui32")
        XCTAssertTrue(success)
        let written = conn.writtenKeys.first!
        XCTAssertEqual(written.key, "CHTE")
        XCTAssertEqual(written.dataType, smcEncodeKey("ui32"))
        XCTAssertEqual(written.bytes, [0, 0, 0, 1])
    }

    func testWriteKeyValueUnknownTypeReturnsFalse() {
        let conn = FakeSMCConnection(isOpen: true)
        let service = SMCService(connection: conn)

        XCTAssertFalse(service.writeKeyValue("X", value: 1.0, dataType: "abcd"))
        XCTAssertTrue(conn.writtenKeys.isEmpty)
    }

    // MARK: - Open probe

    func testOpenProbeAsksForTheUniversalKeyCountKey() {
        var probedKey: UInt32 = 0
        _ = HardwareSMCConnection.probeIndicatesOpen { input, _ in
            probedKey = input.key
            return false
        }
        XCTAssertEqual(smcDecodeKey(probedKey), "#KEY")
    }

    func testOpenProbeSucceedsWhenTheSMCReportsSuccess() {
        let open = HardwareSMCConnection.probeIndicatesOpen { _, output in
            output.data[40] = 0 // result == kSMCSuccess
            return true
        }
        XCTAssertTrue(open)
    }

    /// The regression from #210: on macOS builds that reject the raw AppleSMC
    /// interface, the transport call succeeds while the firmware answers
    /// kSMCKeyNotFound for every key — including `#KEY`. That is not an open
    /// connection, and reporting it as one makes `smc_supported` lie.
    func testOpenProbeFailsWhenTransportSucceedsButSMCRejectsTheKey() {
        let open = HardwareSMCConnection.probeIndicatesOpen { _, output in
            output.data[40] = 132 // kSMCKeyNotFound
            return true
        }
        XCTAssertFalse(open)
    }

    func testOpenProbeFailsWhenTheTransportCallFails() {
        XCTAssertFalse(HardwareSMCConnection.probeIndicatesOpen { _, _ in false })
    }

    // MARK: - System power (readSystemPower)

    private func fltKey(_ value: Double) -> FakeSMCKeyResult {
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

    func testReadSystemPowerNilWhenConnectionClosed() {
        let service = SMCService(connection: FakeSMCConnection(isOpen: false))
        XCTAssertNil(service.readSystemPower())
    }

    func testReadSystemPowerNilWhenKeysAbsent() {
        let service = SMCService(connection: FakeSMCConnection(isOpen: true, keys: [:]))
        XCTAssertNil(service.readSystemPower())
    }

    func testReadSystemPowerReadsAllThreeKeys() {
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "VD0R": fltKey(20.0),
            "ID0R": fltKey(0.5),
            "PDTR": fltKey(10.0)
        ])
        let service = SMCService(connection: conn)

        let power = service.readSystemPower()
        XCTAssertEqual(power?.volts ?? 0, 20.0, accuracy: 0.0001)
        XCTAssertEqual(power?.amps ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(power?.watts ?? 0, 10.0, accuracy: 0.0001)
        // Read-only: a power read must never write to the SMC.
        XCTAssertTrue(conn.writtenKeys.isEmpty)
    }

    func testReadSystemPowerWattsConsistentWithVoltsTimesAmps() {
        let volts = 20.3
        let amps = 0.12
        let watts = volts * amps
        let service = SMCService(connection: FakeSMCConnection(isOpen: true, keys: [
            "VD0R": fltKey(volts),
            "ID0R": fltKey(amps),
            "PDTR": fltKey(watts)
        ]))

        let power = service.readSystemPower()
        guard let power, let volts = power.volts, let amps = power.amps, let watts = power.watts else {
            return XCTFail("expected a full power report")
        }
        XCTAssertEqual(watts, volts * amps, accuracy: 0.0001)
    }

    func testReadSystemPowerPartialWattsOnlyStillReported() {
        let service = SMCService(connection: FakeSMCConnection(isOpen: true, keys: [
            "PDTR": fltKey(4.2)
        ]))

        let power = service.readSystemPower()
        XCTAssertEqual(power?.watts ?? 0, 4.2, accuracy: 0.0001)
        XCTAssertNil(power?.volts)
        XCTAssertNil(power?.amps)
    }

    // MARK: - Chip generation detection (issue #233)

    func testChipGenerationDetectionFromBrandString() {
        XCTAssertEqual(SMCService.chipGeneration(fromBrandString: "Apple M1"), .m1)
        XCTAssertEqual(SMCService.chipGeneration(fromBrandString: "Apple M2 Pro"), .m2)
        XCTAssertEqual(SMCService.chipGeneration(fromBrandString: "Apple M3 Max"), .m3)
        XCTAssertEqual(SMCService.chipGeneration(fromBrandString: "Apple M4 Pro"), .m4)
        XCTAssertNil(SMCService.chipGeneration(fromBrandString: "Intel Core i9-13900K"))
        XCTAssertNil(SMCService.chipGeneration(fromBrandString: "Apple M5"))
    }

    func testAppleSiliconTablesAreGenerationAware() {
        let m3Keys = Set(SMCService.appleSiliconTemperatureKeys(for: .m3).map { $0.key })
        let m4Keys = Set(SMCService.appleSiliconTemperatureKeys(for: .m4).map { $0.key })

        // M3 carries the M3 E-core row…
        XCTAssertTrue(m3Keys.contains("Te0L"))
        XCTAssertTrue(m3Keys.contains("Te0P"))
        // …the M4 row carries the M4 E-core keys instead.
        XCTAssertTrue(m4Keys.contains("Te09"))
        XCTAssertTrue(m4Keys.contains("Te0H"))
        XCTAssertFalse(m4Keys.contains("Te0L"))
        // CPU die hotspot (TCMz) and GPU die hotspot (TRDX) are in every row.
        XCTAssertTrue(m3Keys.contains("TCMz"))
        XCTAssertTrue(m4Keys.contains("TRDX"))
    }

    func testUnknownGenerationUsesUnionOfECoreRows() {
        let keys = Set(SMCService.appleSiliconTemperatureKeys(for: .unknown).map { $0.key })
        for eCoreKey in ["Te04", "Te05", "Te06", "Te09", "Te0H", "Te0L", "Te0P", "Te0S"] {
            XCTAssertTrue(keys.contains(eCoreKey), "unknown row must carry \(eCoreKey)")
        }
    }

    // MARK: - Key enumeration & intersection (issue #233)

    /// The candidate table used by `readTemperatures` on the current arch,
    /// so intersection tests are deterministic on both arm64 and x86_64.
    private var currentArchTable: [(key: String, label: String)] {
        #if arch(arm64)
        return SMCService.appleSiliconTemperatureKeys(for: .m4)
        #else
        return SMCService.intelTempKeys
        #endif
    }

    func testEnumerationFiltersTemperatureKeysToIntersection() {
        let table = currentArchTable
        let fpe2 = smcEncodeKey("fpe2")

        // Host exposes only one table key plus a foreign key.
        let exposed = [table[0].key, "ZZZZ"]
        var keys: [String: FakeSMCKeyResult] = [:]
        for (key, _) in table where exposed.contains(key) {
            keys[key] = FakeSMCKeyResult(dataType: fpe2, bytes: [0x01, 0x00])
        }
        keys["ZZZZ"] = FakeSMCKeyResult(dataType: fpe2, bytes: [0x01, 0x00])

        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.enumeratedKeys = exposed
        let service = SMCService(connection: conn)

        XCTAssertTrue(service.keyEnumerationAvailable)
        let readings = service.readTemperatures()
        // Only the intersection of the candidate table and the enumeration
        // is reported; the foreign key is ignored.
        XCTAssertEqual(readings.map(\.key), [table[0].key])
        // Absent keys are never reported as zero or unknown.
        XCTAssertFalse(readings.contains { $0.celsius <= 0 })
    }

    func testEnumerationUnavailableFallsBackToCandidateTable() {
        let table = currentArchTable
        let fpe2 = smcEncodeKey("fpe2")

        var keys: [String: FakeSMCKeyResult] = [:]
        for (key, _) in table {
            keys[key] = FakeSMCKeyResult(dataType: fpe2, bytes: [0x01, 0x00])
        }
        let conn = FakeSMCConnection(isOpen: true, keys: keys)
        conn.enumeratedKeys = nil // enumeration unavailable
        let service = SMCService(connection: conn)

        XCTAssertFalse(service.keyEnumerationAvailable)
        XCTAssertNil(service.enumerateKeys())
        XCTAssertEqual(service.readTemperatures().count, table.count)
    }

    func testEnumeratedKeysOutsideTableAreNotReported() {
        let fpe2 = smcEncodeKey("fpe2")
        // The host exposes only a key that is NOT a candidate in the table.
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "Te0Q": FakeSMCKeyResult(dataType: fpe2, bytes: [0x01, 0x00])
        ])
        conn.enumeratedKeys = ["Te0Q"]
        let service = SMCService(connection: conn)

        XCTAssertTrue(service.keyEnumerationAvailable)
        XCTAssertEqual(service.readTemperatures(), [])
    }

    func testEnumerationUnavailableWhenConnectionClosed() {
        let conn = FakeSMCConnection(isOpen: false)
        conn.enumeratedKeys = ["TCMz"]
        let service = SMCService(connection: conn)

        XCTAssertFalse(service.keyEnumerationAvailable)
        XCTAssertNil(service.enumerateKeys())
        XCTAssertEqual(service.readTemperatures(), [])
    }

    func testHardwareConnectionEnumeratesKeysByIndex() {
        let ui32 = smcEncodeKey("ui32")
        let exposedKeys = ["TCMz", "Te05", "Te0S", "TRDX"]
        let connection = HardwareSMCConnection(isOpen: true) { input, output in
            // kSMCGetKeyFromIndex (8): index in data32, key code in output.key.
            if input.data8 == 8 {
                let index = Int(input.data32)
                guard index < exposedKeys.count else {
                    output.data[40] = 132 // kSMCKeyNotFound — past the end
                    return true
                }
                output.data[40] = 0
                output.key = smcEncodeKey(exposedKeys[index])
                return true
            }
            // #KEY keyinfo (9) + read (5): ui32 count.
            if smcDecodeKey(input.key) == "#KEY" {
                output.data[40] = 0
                output.keyInfoDataSize = 4
                output.keyInfoDataType = ui32
                if input.data8 == 5 {
                    let count = UInt32(exposedKeys.count)
                    output.data[48] = UInt8((count >> 24) & 0xFF)
                    output.data[49] = UInt8((count >> 16) & 0xFF)
                    output.data[50] = UInt8((count >> 8) & 0xFF)
                    output.data[51] = UInt8(count & 0xFF)
                }
                return true
            }
            return false
        }

        XCTAssertEqual(connection.enumerateKeys(), exposedKeys)
        // Cached: the second call repeats the result without new round-trips.
        XCTAssertEqual(connection.enumerateKeys(), exposedKeys)
    }

    #if arch(arm64)
    func testM4GenerationSkipsDeliberatelyAbsentKey() {
        let fpe2 = smcEncodeKey("fpe2")
        // The M4 row expects Te05/Te0S/Te09/Te0H; Te0H is deliberately absent
        // from this host's enumeration and key table.
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "TCMz": FakeSMCKeyResult(dataType: fpe2, bytes: [0x10, 0x00]),
            "Te05": FakeSMCKeyResult(dataType: fpe2, bytes: [0x20, 0x00]),
            "Te0S": FakeSMCKeyResult(dataType: fpe2, bytes: [0x30, 0x00]),
            "Te09": FakeSMCKeyResult(dataType: fpe2, bytes: [0x40, 0x00]),
        ])
        conn.enumeratedKeys = ["TCMz", "Te05", "Te0S", "Te09"]
        let service = SMCService(connection: conn, generation: .m4)

        let readings = service.readTemperatures()
        let reported = Set(readings.map(\.key))
        XCTAssertTrue(reported.contains("TCMz"))
        XCTAssertTrue(reported.contains("Te05"))
        XCTAssertFalse(reported.contains("Te0H"))
        XCTAssertFalse(reported.contains("Te0L"))
        // Absent keys are omitted — never reported as zero or unknown.
        XCTAssertFalse(readings.contains { $0.celsius <= 0 })
    }
    #endif
}

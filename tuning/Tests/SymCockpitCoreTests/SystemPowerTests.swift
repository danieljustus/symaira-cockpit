import XCTest
@testable import SymCockpitCore

/// Issue #403: total system power is reported separately from the DC-in
/// adapter rail. All SMC and battery access goes through fakes.
final class SystemPowerTests: XCTestCase {
    private func fltKey(_ value: Double) -> FakeSMCKeyResult {
        let raw = Float(value).bitPattern
        return FakeSMCKeyResult(
            dataType: smcEncodeKey("flt "),
            // `flt ` is little-endian on the wire (issue #185).
            bytes: [
                UInt8(raw & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 24) & 0xFF)
            ]
        )
    }

    private func service(_ keys: [String: Double], isOpen: Bool = true) -> SMCService {
        SMCService(connection: FakeSMCConnection(
            isOpen: isOpen,
            keys: keys.mapValues { fltKey($0) }
        ))
    }

    // MARK: - SMC PSTR

    func testPSTRIsReportedAsSystemWattsSeparateFromAdapter() {
        let power = service([
            "VD0R": 20.0, "ID0R": 0.5, "PDTR": 10.0, "PSTR": 23.5
        ]).readSystemPower()

        XCTAssertEqual(power?.systemWatts ?? 0, 23.5, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .smcPSTR)
        XCTAssertEqual(power?.watts ?? 0, 10.0, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterWatts ?? 0, 10.0, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterSource, .smcPDTR)
    }

    func testPSTRWinsOverBatterySystemLoad() {
        let power = service(["PSTR": 12.0]).readSystemPower(systemLoadFallbackMilliwatts: { 99_000 })
        XCTAssertEqual(power?.systemWatts ?? 0, 12.0, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .smcPSTR)
    }

    func testSystemWattsReadWithoutAnyAdapterKeys() {
        let power = service(["PSTR": 8.0]).readSystemPower()
        XCTAssertEqual(power?.systemWatts ?? 0, 8.0, accuracy: 0.0001)
        XCTAssertNil(power?.watts)
        XCTAssertNil(power?.adapterWatts)
        XCTAssertNil(power?.adapterSource)
    }

    // MARK: - Battery SystemLoad fallback

    func testMissingPSTRFallsBackToBatterySystemLoad() {
        let power = service(["VD0R": 20.0, "ID0R": 0.0, "PDTR": 0.0])
            .readSystemPower(systemLoadFallbackMilliwatts: { 19_233 })

        XCTAssertEqual(power?.systemWatts ?? 0, 19.233, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .batterySystemLoad)
    }

    func testNonPositivePSTRFallsBackToBatterySystemLoad() {
        let power = service(["PSTR": 0.0]).readSystemPower(systemLoadFallbackMilliwatts: { 5_500 })
        XCTAssertEqual(power?.systemWatts ?? 0, 5.5, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .batterySystemLoad)
    }

    func testBatterySystemLoadWorksWhenSMCConnectionIsClosed() {
        let power = service([:], isOpen: false).readSystemPower(systemLoadFallbackMilliwatts: { 7_000 })
        XCTAssertEqual(power?.systemWatts ?? 0, 7.0, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .batterySystemLoad)
        XCTAssertNil(power?.watts)
    }

    func testFallbackIsNotConsultedWhenPSTRIsPresent() {
        var consulted = false
        _ = service(["PSTR": 3.0]).readSystemPower(systemLoadFallbackMilliwatts: {
            consulted = true
            return 1
        })
        XCTAssertFalse(consulted, "the battery must not be read when the SMC already has a total")
    }

    // MARK: - PD0R adapter fallback

    func testPDTRZeroWithPD0RPresentUsesPD0RForAdapter() {
        let power = service(["PDTR": 0.0, "PD0R": 41.5]).readSystemPower()
        XCTAssertEqual(power?.watts ?? 0, 41.5, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterWatts ?? 0, 41.5, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterSource, .smcPD0R)
    }

    func testPDTRAbsentWithPD0RPresentUsesPD0RForAdapter() {
        let power = service(["PD0R": 17.0]).readSystemPower()
        XCTAssertEqual(power?.watts ?? 0, 17.0, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterSource, .smcPD0R)
    }

    func testNonZeroPDTRIsNotOverriddenByPD0R() {
        let power = service(["PDTR": 9.0, "PD0R": 41.5]).readSystemPower()
        XCTAssertEqual(power?.watts ?? 0, 9.0, accuracy: 0.0001)
        XCTAssertEqual(power?.adapterSource, .smcPDTR)
    }

    func testGenuineZeroPDTRIsKeptWhenPD0RIsAbsent() {
        // On battery the adapter draws nothing; that is a real reading.
        let power = service(["PDTR": 0.0, "PSTR": 6.0]).readSystemPower()
        XCTAssertEqual(power?.watts, 0.0)
        XCTAssertEqual(power?.adapterSource, .smcPDTR)
    }

    // MARK: - Absent, not zero

    func testNothingReadableYieldsNilNotZeros() {
        XCTAssertNil(service([:]).readSystemPower())
        XCTAssertNil(service([:]).readSystemPower(systemLoadFallbackMilliwatts: { nil }))
        XCTAssertNil(service([:]).readSystemPower(systemLoadFallbackMilliwatts: { 0 }))
    }

    func testMissingKeysLeaveFieldsAbsentInJSON() throws {
        let power = try XCTUnwrap(service(["PD0R": 17.0]).readSystemPower())
        let json = try Self.json(power)
        XCTAssertNil(json["system_watts"])
        XCTAssertNil(json["system_source"])
        XCTAssertNil(json["volts"])
        XCTAssertNil(json["amps"])
        XCTAssertEqual(json["adapter_watts"] as? Double, 17.0)
    }

    func testPSTRReadNeverWritesToTheSMC() {
        let conn = FakeSMCConnection(isOpen: true, keys: ["PSTR": fltKey(5.0), "PDTR": fltKey(0)])
        _ = SMCService(connection: conn).readSystemPower()
        XCTAssertTrue(conn.writtenKeys.isEmpty)
    }

    // MARK: - JSON snapshot

    func testPowerJSONShapeSnapshot() throws {
        let power = PowerReport(
            volts: 20.0,
            amps: 0.5,
            watts: 10.0,
            adapterSource: .smcPDTR,
            systemWatts: 23.5,
            systemSource: .smcPSTR
        )
        let json = try Self.json(power)

        // Existing fields keep their names and meaning (DC-in adapter input).
        XCTAssertEqual(json["volts"] as? Double, 20.0)
        XCTAssertEqual(json["amps"] as? Double, 0.5)
        XCTAssertEqual(json["watts"] as? Double, 10.0)
        // New, explicitly labelled fields.
        XCTAssertEqual(json["adapter_watts"] as? Double, 10.0)
        XCTAssertEqual(json["adapter_source"] as? String, "smc_pdtr")
        XCTAssertEqual(json["system_watts"] as? Double, 23.5)
        XCTAssertEqual(json["system_source"] as? String, "smc_pstr")
        XCTAssertEqual(
            Set(json.keys),
            ["volts", "amps", "watts", "adapter_watts", "adapter_source", "system_watts", "system_source"]
        )
    }

    func testBatterySystemLoadSourceSerializesAsLabel() throws {
        let power = PowerReport(systemWatts: 19.233, systemSource: .batterySystemLoad)
        let json = try Self.json(power)
        XCTAssertEqual(json["system_source"] as? String, "battery_system_load")
        XCTAssertEqual(Set(json.keys), ["system_watts", "system_source"])
    }

    func testPowerReportRoundTripsAndOldPayloadsStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let old = Data(#"{"volts":20,"amps":0.5,"watts":10}"#.utf8)
        let decoded = try decoder.decode(PowerReport.self, from: old)
        XCTAssertEqual(decoded.watts, 10)
        XCTAssertNil(decoded.systemWatts)
    }

    // MARK: - AppleSmartBattery mapping

    func testRegistryExposesSystemLoadFromPowerTelemetry() {
        let props = HardwareBatterySource.properties(fromRegistry: [
            "ExternalConnected": true,
            "PowerTelemetryData": ["SystemLoad": 19233, "SystemPowerIn": 36515] as [String: Any]
        ])
        XCTAssertEqual(props.systemLoadMilliwatts, 19233)
    }

    func testRegistryWithoutTelemetryLeavesSystemLoadAbsent() {
        XCTAssertNil(HardwareBatterySource.properties(fromRegistry: ["ExternalConnected": true]).systemLoadMilliwatts)
        XCTAssertNil(HardwareBatterySource.properties(fromRegistry: [
            "PowerTelemetryData": ["SystemPowerIn": 1] as [String: Any]
        ]).systemLoadMilliwatts)
    }

    // MARK: - Metrics source wiring

    func testMetricsSourceFallsBackToInjectedBatterySystemLoad() {
        let battery = FakeBatterySource(result: .success(BatteryProperties(systemLoadMilliwatts: 11_250)))
        let source = HardwareSystemMetricsSource(
            smc: service(["PDTR": 0.0]),
            batterySource: battery
        )
        let power = source.readSnapshot().power
        XCTAssertEqual(power?.systemWatts ?? 0, 11.25, accuracy: 0.0001)
        XCTAssertEqual(power?.systemSource, .batterySystemLoad)
    }

    func testMetricsSourceOmitsPowerWhenNeitherSourceHasData() {
        let source = HardwareSystemMetricsSource(
            smc: service([:]),
            batterySource: FakeBatterySource(result: .unavailable)
        )
        XCTAssertNil(source.readSnapshot().power)
    }

    // MARK: - Capability text

    func testCapabilityDetailSeparatesTotalFromAdapter() {
        let detail = TuneController.powerDrawDetail(PowerReport(
            volts: 20, amps: 0.5, watts: 10, adapterSource: .smcPDTR,
            systemWatts: 23.5, systemSource: .smcPSTR
        ))
        XCTAssertTrue(detail.contains("total system power"))
        XCTAssertTrue(detail.contains("PSTR"))
        XCTAssertTrue(detail.contains("adapter DC-in input only"))
        XCTAssertTrue(detail.contains("not the Mac's consumption"))
    }

    func testCapabilityDetailNamesBatteryFallbackAndPD0R() {
        let detail = TuneController.powerDrawDetail(PowerReport(
            watts: 40, adapterSource: .smcPD0R,
            systemWatts: 19.2, systemSource: .batterySystemLoad
        ))
        XCTAssertTrue(detail.contains("PowerTelemetryData.SystemLoad"))
        XCTAssertTrue(detail.contains("PD0R"))
    }

    func testCapabilityDetailWhenNothingIsExposed() {
        let detail = TuneController.powerDrawDetail(nil)
        XCTAssertTrue(detail.contains("No power readings"))
    }

    func testCapabilityDetailFlagsMissingTotal() {
        let detail = TuneController.powerDrawDetail(PowerReport(watts: 10, adapterSource: .smcPDTR))
        XCTAssertTrue(detail.contains("total system power (system_watts) unavailable"))
    }

    // MARK: - Helper

    private static func json(_ power: PowerReport) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(power)) as? [String: Any]
        )
    }
}

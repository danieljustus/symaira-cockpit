import XCTest
@testable import SymTuneCore

/// Tests for `HardwareBatterySource` — the real IORegistry read and the
/// `IOPowerSources` fallback (dlopen/dlsym). The injected service-lookup and
/// API-loader seams make every branch unit-testable without hardware.
final class HardwareBatterySourceTests: XCTestCase {
    /// CF objects are not Sendable; boxes make them capturable by the
    /// `@Sendable` seam closures (read-only access at call time).
    private final class SendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private func makeSource(
        service: io_service_t,
        api: HardwareBatterySource.PowerSourcesAPI?
    ) -> HardwareBatterySource {
        HardwareBatterySource(
            serviceLookup: { service },
            loadAPI: { api }
        )
    }

    private func makeAPI(
        info: CFTypeRef?,
        list: CFArray?
    ) -> HardwareBatterySource.PowerSourcesAPI {
        let infoBox = SendableBox(info)
        let listBox = SendableBox(list)
        return HardwareBatterySource.PowerSourcesAPI(
            copyPowerSourcesInfo: { infoBox.value },
            copyDescriptionList: { _ in listBox.value }
        )
    }

    private func makeList(_ dicts: [[String: Any]]) -> CFArray {
        dicts.map { $0 as NSDictionary } as CFArray
    }

    // MARK: - Service-lookup guard branches

    func testMissingServiceWithUnloadableAPIIsUnavailable() {
        let source = makeSource(service: 0, api: nil)
        XCTAssertEqual(source.readProperties(), .unavailable)
    }

    func testMissingServiceWithEmptySnapshotIsUnavailable() {
        let api = makeAPI(info: nil, list: nil)
        let source = makeSource(service: 0, api: api)
        XCTAssertEqual(source.readProperties(), .unavailable)
    }

    func testMissingServiceWithUncastableDescriptionListIsUnavailable() {
        let api = makeAPI(info: "snapshot" as CFString, list: nil)
        let source = makeSource(service: 0, api: api)
        XCTAssertEqual(source.readProperties(), .unavailable)
    }

    // MARK: - Registry key mapping

    /// The `AppleSmartBattery` node on an M-series Mac (macOS 27): the
    /// top-level `MaxCapacity` / `CurrentCapacity` are **percentages**, there is
    /// no top-level `DesignCapacity` and no `AppleRaw*` key, and the
    /// milliamp-hour figures live in the nested `BatteryData` dictionary.
    static func appleSiliconRegistry() -> [String: Any] {
        [
        "IsCharging": false,
        "ExternalConnected": true,
        "CurrentCapacity": 100,
        "MaxCapacity": 100,
        "CycleCount": 136,
        "BatteryData": [
            "DesignCapacity": 6249,
            "NominalChargeCapacity": 5701,
            "FullChargeCapacity": 5549,
            "RemainingCapacity": 5466,
            "MaxCapacity": 100,
            "CurrentCapacity": 100,
            ] as [String: Any],
        ]
    }

    /// Regression for #232: `MaxCapacity` was published as `max_capacity_mah`,
    /// so a 6249 mAh battery reported 100 mAh, and `DesignCapacity` was looked
    /// up only at the top level, so health could never be computed.
    func testAppleSiliconRegistryReadsMilliampHoursFromBatteryData() {
        let parsed = HardwareBatterySource.properties(fromRegistry: Self.appleSiliconRegistry())

        XCTAssertEqual(parsed.designCapacity, 6249, "design capacity lives in BatteryData on Apple Silicon")
        XCTAssertEqual(parsed.rawMaxCapacity, 5701, "a percentage must never be reported as a mAh capacity")
        XCTAssertEqual(parsed.cycleCount, 136)
        XCTAssertEqual(parsed.externalConnected, true)
    }

    /// Intel reports the same two keys in milliamp-hours and exposes the
    /// `AppleRaw*` pair. That mapping must not change.
    func testIntelRegistryKeepsTheTopLevelMilliampHourKeys() {
        let props: [String: Any] = [
            "IsCharging": true,
            "ExternalConnected": true,
            "DesignCapacity": 8790,
            "MaxCapacity": 8100,
            "CurrentCapacity": 6400,
            "AppleRawMaxCapacity": 8060,
            "AppleRawCurrentCapacity": 6380,
            "CycleCount": 310,
            "Temperature": 3021,
        ]

        let parsed = HardwareBatterySource.properties(fromRegistry: props)

        XCTAssertEqual(parsed.designCapacity, 8790)
        XCTAssertEqual(parsed.rawMaxCapacity, 8060, "AppleRawMaxCapacity still wins where it exists")
        XCTAssertEqual(parsed.rawCurrentCapacity, 6380)
        XCTAssertEqual(parsed.temperatureCentidegrees, 3021)
    }

    /// End-to-end through `BatteryService`: what the CLI actually publishes for
    /// the Apple Silicon node above.
    func testAppleSiliconReportPublishesCapacityAndHealth() {
        struct FixedSource: BatterySource {
            let properties: BatteryProperties
            func readProperties() -> BatterySourceResult { .success(properties) }
        }

        let report = BatteryService(
            source: FixedSource(
                properties: HardwareBatterySource.properties(fromRegistry: Self.appleSiliconRegistry())
            )
        ).read()

        XCTAssertEqual(report.maxCapacityMah, 5701, "max_capacity_mah must be milliamp-hours, not 100 %")
        XCTAssertEqual(report.designCapacityMah, 6249)
        XCTAssertEqual(report.healthPercent, 91, "5701 / 6249 — both milliamp-hours")
        XCTAssertEqual(
            report.currentCapacityPercent, 100,
            "state of charge must stay at the 100 % macOS itself reports, not become 5466/5701"
        )
    }

    // MARK: - Fallback parsing

    func testFallbackSkipsNonBatteryPowerSources() {
        let api = makeAPI(
            info: "snapshot" as CFString,
            list: makeList([["Type": "AC Power"]])
        )
        let source = makeSource(service: 0, api: api)
        XCTAssertEqual(source.readProperties(), .unavailable)
    }

    func testFallbackParsesInternalBatteryDictionary() {
        let api = makeAPI(
            info: "snapshot" as CFString,
            list: makeList([[
                "Type": "InternalBattery",
                "Is Charging": true,
                "Power Source State": "AC Power",
                "Max Capacity": 100,
                "Current Capacity": 80,
                "Cycle Count": 42
            ]])
        )
        let source = makeSource(service: 0, api: api)

        guard case .success(let props) = source.readProperties() else {
            return XCTFail("expected .success from the IOPowerSources fallback")
        }
        XCTAssertEqual(props.isCharging, true)
        XCTAssertEqual(props.externalConnected, true)
        XCTAssertEqual(props.chargePercent, 80, "the IOPowerSources pair is a percentage")
        XCTAssertEqual(props.cycleCount, 42)
        // IOPowerSources reports no milliamp-hour figure at all — publishing its
        // percentage pair as one was the same defect as #232 on the registry path.
        XCTAssertNil(props.rawMaxCapacity)
        XCTAssertNil(props.rawCurrentCapacity)
        XCTAssertNil(props.designCapacity)
        XCTAssertNil(props.temperatureCentidegrees)
    }

    func testFallbackPrefersFirstInternalBattery() {
        let api = makeAPI(
            info: "snapshot" as CFString,
            list: makeList([
                ["Type": "AC Power"],
                ["Type": "InternalBattery", "Max Capacity": 90, "Current Capacity": 45],
                ["Type": "InternalBattery", "Max Capacity": 80, "Current Capacity": 40]
            ])
        )
        let source = makeSource(service: 0, api: api)

        guard case .success(let props) = source.readProperties() else {
            return XCTFail("expected .success from the IOPowerSources fallback")
        }
        XCTAssertEqual(props.chargePercent, 50, "45 of 90 — the first internal battery, as a percentage")
    }

    // MARK: - Real paths on this machine

    func testRealAPILoaderDegradesGracefullyOnThisOS() {
        // The IOPowerSources symbols are not exported from IOKit on macOS 27
        // (verified via nm + dlsym), so the loader may legitimately return nil
        // here. What must hold on every OS: no crash, and a nil loader means
        // the fallback degrades to .unavailable instead of trapping.
        let loader = HardwareBatterySource.loadPowerSourcesAPI()
        if loader == nil {
            let source = makeSource(service: 0, api: nil)
            XCTAssertEqual(source.readProperties(), .unavailable)
        } else {
            XCTAssertNotNil(loader)
        }
    }

    func testRealFallbackRunsAgainstSystemFrameworks() {
        let source = makeSource(service: 0, api: HardwareBatterySource.loadPowerSourcesAPI())
        switch source.readProperties() {
        case .success(let props):
            // This machine has a battery: the fallback parsed it.
            XCTAssertNotNil(props.chargePercent)
        case .unavailable, .readFailed:
            break // Desktop Mac or unreadable snapshot: still a valid result.
        }
    }

    func testRealSourceRunsWithoutInjection() {
        let result = HardwareBatterySource().readProperties()
        switch result {
        case .success(let props):
            XCTAssertNotNil(props.rawMaxCapacity)
        case .unavailable, .readFailed:
            break
        }
    }
}

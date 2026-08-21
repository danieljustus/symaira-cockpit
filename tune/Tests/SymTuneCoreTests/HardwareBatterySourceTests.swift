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
        XCTAssertEqual(props.rawMaxCapacity, 100)
        XCTAssertEqual(props.rawCurrentCapacity, 80)
        XCTAssertEqual(props.cycleCount, 42)
        // Not exposed by the public IOPowerSources API
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
        XCTAssertEqual(props.rawMaxCapacity, 90)
        XCTAssertEqual(props.rawCurrentCapacity, 45)
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
            XCTAssertNotNil(props.rawMaxCapacity)
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

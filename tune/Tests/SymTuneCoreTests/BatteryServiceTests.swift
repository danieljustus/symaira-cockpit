import XCTest
@testable import SymTuneCore

final class BatteryServiceTests: XCTestCase {
    func testUnavailableReturnsDesktopReport() {
        let source = FakeBatterySource(result: .unavailable)
        let report = BatteryService(source: source).read()

        XCTAssertFalse(report.present)
        XCTAssertNil(report.charging)
        XCTAssertNil(report.externalConnected)
        XCTAssertNil(report.currentCapacityPercent)
        XCTAssertNil(report.cycleCount)
        XCTAssertNil(report.designCapacityMah)
        XCTAssertNil(report.maxCapacityMah)
        XCTAssertNil(report.healthPercent)
        XCTAssertNil(report.temperatureCelsius)
        XCTAssertEqual(report.notes.first, "No AppleSmartBattery node — likely a desktop Mac.")
    }

    func testReadFailedReturnsPresentButEmpty() {
        let source = FakeBatterySource(result: .readFailed)
        let report = BatteryService(source: source).read()

        XCTAssertTrue(report.present)
        XCTAssertNil(report.charging)
        XCTAssertNil(report.externalConnected)
        XCTAssertNil(report.currentCapacityPercent)
        XCTAssertNil(report.cycleCount)
        XCTAssertNil(report.designCapacityMah)
        XCTAssertNil(report.maxCapacityMah)
        XCTAssertNil(report.healthPercent)
        XCTAssertNil(report.temperatureCelsius)
        XCTAssertEqual(report.notes.first, "Failed to read AppleSmartBattery properties.")
    }

    func testPartialDataOmitsHealth() {
        let props = BatteryProperties(
            isCharging: true,
            externalConnected: true,
            rawMaxCapacity: 8000,
            rawCurrentCapacity: 4000,
            temperatureCentidegrees: 2500
        )
        let source = FakeBatterySource(result: .success(props))
        let report = BatteryService(source: source).read()

        XCTAssertTrue(report.present)
        XCTAssertEqual(report.charging, true)
        XCTAssertEqual(report.externalConnected, true)
        XCTAssertEqual(report.currentCapacityPercent, 50)
        XCTAssertNil(report.healthPercent)
        XCTAssertEqual(report.maxCapacityMah, 8000)
        XCTAssertEqual(report.temperatureCelsius, 25.0)
    }

    func testFullDataComputesHealthAndPercent() {
        let props = BatteryProperties(
            isCharging: false,
            externalConnected: false,
            designCapacity: 10000,
            rawMaxCapacity: 9000,
            rawCurrentCapacity: 4500,
            cycleCount: 42,
            temperatureCentidegrees: 3000
        )
        let source = FakeBatterySource(result: .success(props))
        let report = BatteryService(source: source).read()

        XCTAssertTrue(report.present)
        XCTAssertEqual(report.charging, false)
        XCTAssertEqual(report.externalConnected, false)
        XCTAssertEqual(report.currentCapacityPercent, 50)
        XCTAssertEqual(report.cycleCount, 42)
        XCTAssertEqual(report.designCapacityMah, 10000)
        XCTAssertEqual(report.maxCapacityMah, 9000)
        XCTAssertEqual(report.healthPercent, 90)
        XCTAssertEqual(report.temperatureCelsius, 30.0)
    }

    func testCapacityPercentIsClampedTo100() {
        let props = BatteryProperties(
            rawMaxCapacity: 100,
            rawCurrentCapacity: 999
        )
        let source = FakeBatterySource(result: .success(props))
        let report = BatteryService(source: source).read()

        XCTAssertEqual(report.currentCapacityPercent, 100)
    }

    func testChargeLimitSupportedWhenClosureReturnsTrue() {
        let props = BatteryProperties(
            isCharging: true,
            externalConnected: true
        )
        let source = FakeBatterySource(result: .success(props))
        let service = BatteryService(source: source, isChargeLimitSupported: { true })
        let report = service.read()
        XCTAssertTrue(report.present)
        XCTAssertTrue(report.chargeLimitSupported)
    }

    func testChargeLimitUnsupportedWhenClosureReturnsFalse() {
        let props = BatteryProperties(
            isCharging: true,
            externalConnected: true
        )
        let source = FakeBatterySource(result: .success(props))
        let service = BatteryService(source: source, isChargeLimitSupported: { false })
        let report = service.read()
        XCTAssertTrue(report.present)
        XCTAssertFalse(report.chargeLimitSupported)
        XCTAssertTrue(report.notes.contains("Charge-limit SMC key not detected on this Mac."))
    }
}

import XCTest
@testable import SymTuneCore

final class BatteryHealthParserTests: XCTestCase {
    /// Captured from `system_profiler SPPowerDataType` on a real Mac
    /// (macOS 27, Apple Silicon, battery present). Serial redacted.
    private let capturedFixture = """
    Power:

        Battery Information:

          Model Information:
              Serial Number: XXXXXXXXXXXX
              Device Name: bq40z651
              Pack Lot Code: 0
              PCB Lot Code: 0
              Firmware Version: 0b00
              Hardware Revision: 100
              Cell Revision: 271d
          Charge Information:
              The battery’s charge is below the warning level: No
              Fully Charged: Yes
              Charging: No
              State of Charge (%): 100
          Health Information:
              Cycle Count: 120
              Condition: Normal
              Maximum Capacity: 97 %

        System Power Settings:

          AC Power:
              System Sleep Timer (Minutes): 1
              Disk Sleep Timer (Minutes): 10
              Display Sleep Timer (Minutes): 10
              Sleep on Power Button: Yes
              Wake on LAN: Yes
              Current Power Source: Yes
              Hibernate Mode: 3
              High Power Mode: No
              Low Power Mode: No
              Prioritize Network Reachability Over Sleep: No
          Battery Power:
              System Sleep Timer (Minutes): 1
              Disk Sleep Timer (Minutes): 10
              Display Sleep Timer (Minutes): 2
              Sleep on Power Button: Yes
              Wake on LAN: No
              Hibernate Mode: 3
              High Power Mode: No
              Low Power Mode: No
              Prioritize Network Reachability Over Sleep: No
              Reduce Brightness: Yes

        Hardware Configuration:

          UPS Installed: No

        AC Charger Information:

          Connected: Yes
          ID: 0x0000
          Wattage (W): 45
          Family: 0xe000400a
          Charging: No
    """

    func testParsesCapturedFixture() {
        let health = BatteryHealthParser.parse(capturedFixture)
        XCTAssertEqual(health.maximumCapacityPercent, 97)
        XCTAssertEqual(health.condition, "Normal")
    }

    func testParsesPercentWithoutSpace() {
        let output = "Health Information:\n    Cycle Count: 10\n    Condition: Normal\n    Maximum Capacity: 89%"
        let health = BatteryHealthParser.parse(output)
        XCTAssertEqual(health.maximumCapacityPercent, 89)
        XCTAssertEqual(health.condition, "Normal")
    }

    func testConditionOnlyLeavesCapacityNil() {
        let output = "Health Information:\n    Condition: Service Battery\n"
        let health = BatteryHealthParser.parse(output)
        XCTAssertNil(health.maximumCapacityPercent)
        XCTAssertEqual(health.condition, "Service Battery")
    }

    func testMalformedInputReturnsNilFields() {
        let garbage = """
        random binary noise
        Condition:
        Maximum Capacity: not-a-number
        Maximum Capacity: %
        Maximum Capacity: 12x
        """
        let health = BatteryHealthParser.parse(garbage)
        XCTAssertNil(health.maximumCapacityPercent)
        XCTAssertNil(health.condition)
    }

    func testMissingHealthBlockReturnsNilFields() {
        let noBattery = "Power:\n    UPS Installed: No\n"
        let health = BatteryHealthParser.parse(noBattery)
        XCTAssertNil(health.maximumCapacityPercent)
        XCTAssertNil(health.condition)
    }

    func testEmptyInputReturnsNilFields() {
        let health = BatteryHealthParser.parse("")
        XCTAssertNil(health.maximumCapacityPercent)
        XCTAssertNil(health.condition)
    }

    // MARK: - BatteryService integration

    private struct StubAppleHealthProvider: AppleBatteryHealthProviding {
        let health: AppleBatteryHealth
        func readAppleHealth() -> AppleBatteryHealth { health }
    }

    func testBatteryServiceReportsAppleFieldsWhenProviderPresent() {
        let props = BatteryProperties(designCapacity: 10000, rawMaxCapacity: 9000)
        let service = BatteryService(
            source: FakeBatterySource(result: .success(props)),
            appleHealthProvider: StubAppleHealthProvider(
                health: AppleBatteryHealth(maximumCapacityPercent: 97, condition: "Normal")
            )
        )
        let report = service.read()
        XCTAssertEqual(report.appleMaximumCapacityPercent, 97)
        XCTAssertEqual(report.appleCondition, "Normal")
        // Computed health and HealthScorer inputs are unchanged.
        XCTAssertEqual(report.healthPercent, 90)
    }

    func testBatteryServiceOmitsAppleFieldsWithoutProvider() {
        let props = BatteryProperties(designCapacity: 10000, rawMaxCapacity: 9000)
        let service = BatteryService(source: FakeBatterySource(result: .success(props)))
        let report = service.read()
        XCTAssertNil(report.appleMaximumCapacityPercent)
        XCTAssertNil(report.appleCondition)
        XCTAssertEqual(report.healthPercent, 90)
    }

    func testAppleFieldsOmittedFromJSONWhenAbsent() throws {
        let report = BatteryReport(
            present: true, charging: nil, externalConnected: nil,
            currentCapacityPercent: nil, cycleCount: nil,
            designCapacityMah: nil, maxCapacityMah: nil, healthPercent: nil,
            temperatureCelsius: nil, chargeLimitSupported: false, notes: []
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any]
        )
        XCTAssertNil(json["apple_maximum_capacity_percent"])
        XCTAssertNil(json["apple_condition"])
    }

    func testAppleFieldsEncodedSnakeCaseWhenPresent() throws {
        let report = BatteryReport(
            present: true, charging: nil, externalConnected: nil,
            currentCapacityPercent: nil, cycleCount: nil,
            designCapacityMah: nil, maxCapacityMah: nil, healthPercent: nil,
            temperatureCelsius: nil,
            appleMaximumCapacityPercent: 97, appleCondition: "Normal",
            chargeLimitSupported: false, notes: []
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any]
        )
        XCTAssertEqual(json["apple_maximum_capacity_percent"] as? Int, 97)
        XCTAssertEqual(json["apple_condition"] as? String, "Normal")
    }

    // MARK: - Provider caching

    func testProviderCachesWithinTTL() {
        let counter = Counter()
        let provider = SystemProfilerBatteryHealthProvider(cacheTTL: 300) {
            counter.increment()
            return AppleBatteryHealth(maximumCapacityPercent: 97, condition: "Normal")
        }
        _ = provider.readAppleHealth()
        _ = provider.readAppleHealth()
        XCTAssertEqual(counter.value, 1)
    }

    func testProviderRefetchesAfterTTL() {
        let counter = Counter()
        let provider = SystemProfilerBatteryHealthProvider(cacheTTL: 0) {
            counter.increment()
            return AppleBatteryHealth(maximumCapacityPercent: 97, condition: "Normal")
        }
        _ = provider.readAppleHealth()
        _ = provider.readAppleHealth()
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - System metrics pass-through

    func testSystemMetricsReportPassesPowerThrough() {
        let snapshot = SystemMetricsSnapshot(
            timestamp: 1,
            cpu: .init(total: [10, 10, 10, 70], perCore: [[10, 10, 10, 70]]),
            memory: .init(usedBytes: 1, freeBytes: 2, wiredBytes: 3, compressedBytes: 4, pressure: nil),
            disk: .init(capacityBytes: 100, usedBytes: 40, freeBytes: 60),
            network: [.init(name: "en0", bytesIn: 1, bytesOut: 1)],
            power: PowerReport(volts: 20.0, amps: 0.5, watts: 10.0)
        )
        let service = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [snapshot]))
        let report = service.read()
        XCTAssertEqual(report.power?.volts, 20.0)
        XCTAssertEqual(report.power?.amps, 0.5)
        XCTAssertEqual(report.power?.watts, 10.0)
    }

    func testSystemMetricsReportOmitsPowerFromJSONWhenAbsent() throws {
        let snapshot = SystemMetricsSnapshot(
            timestamp: 1,
            cpu: .init(total: [10, 10, 10, 70], perCore: [[10, 10, 10, 70]]),
            memory: .init(usedBytes: 1, freeBytes: 2, wiredBytes: 3, compressedBytes: 4, pressure: nil),
            disk: .init(capacityBytes: 100, usedBytes: 40, freeBytes: 60),
            network: [.init(name: "en0", bytesIn: 1, bytesOut: 1)]
        )
        let service = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [snapshot]))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(service.read())) as? [String: Any]
        )
        XCTAssertNil(json["power"])
    }

    // MARK: - Helper

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _value += 1
        }
    }
}

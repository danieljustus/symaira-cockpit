import XCTest
@testable import SymTuneCore

final class StatusTests: XCTestCase {

    func testHealthScorerNominal() {
        let sensors = SensorReport(
            thermalPressure: "nominal",
            smcSupported: true,
            temperatures: [],
            fans: [],
            notes: []
        )
        let battery = BatteryReport(
            present: true,
            charging: false,
            externalConnected: true,
            currentCapacityPercent: 100,
            cycleCount: 100,
            designCapacityMah: 5000,
            maxCapacityMah: 5000,
            healthPercent: 100,
            temperatureCelsius: 25.0,
            chargeLimitSupported: false,
            notes: []
        )
        let overrides = ActiveOverrides(
            brightness: nil,
            dim: nil,
            warmth: nil,
            edrBrightness: nil
        )

        let result = HealthScorer.calculateScore(
            sensors: sensors,
            battery: battery,
            activeOverrides: overrides,
            isKeepAwakeActive: false
        )

        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.message, "System health is optimal.")
        XCTAssertEqual(result.recommendations.count, 1)
        XCTAssertTrue(result.recommendations[0].contains("optimally"))
    }

    func testHealthScorerWarningsAndDegradation() {
        let sensors = SensorReport(
            thermalPressure: "serious",
            smcSupported: false,
            temperatures: [],
            fans: [],
            notes: []
        )
        let battery = BatteryReport(
            present: true,
            charging: false,
            externalConnected: true,
            currentCapacityPercent: 50,
            cycleCount: 1100,
            designCapacityMah: 5000,
            maxCapacityMah: 3750,
            healthPercent: 75, // deficit 5 -> score -5
            temperatureCelsius: 38.0, // warm -> score -5
            chargeLimitSupported: false,
            notes: []
        )
        let overrides = ActiveOverrides(
            brightness: 0.95,
            dim: 0.8,
            warmth: 0.5,
            edrBrightness: 1.2
        )

        let result = HealthScorer.calculateScore(
            sensors: sensors,
            battery: battery,
            activeOverrides: overrides,
            isKeepAwakeActive: true
        )

        // Base 100
        // -30 (thermal serious)
        // -10 (SMC unsupported)
        // -5 (battery health 75)
        // -10 (cycles > 1000)
        // -5 (battery warm 38C)
        // Total = 40. Clamped to 40.
        XCTAssertEqual(result.score, 40)
        XCTAssertEqual(result.message, "System health is critical. Performance or battery may be severely impacted.")
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("serious") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("SMC connection failed") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("degraded (75%)") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("cycle count is high") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("Battery temperature is warm") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("Keep-awake") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("brightness") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("dim") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("Warmth") }))
        XCTAssertTrue(result.recommendations.contains(where: { $0.contains("Extended EDR") }))
    }

    func testHealthScorerCriticalBattery() {
        let sensors = SensorReport(
            thermalPressure: "critical", // -60
            smcSupported: true,
            temperatures: [],
            fans: [],
            notes: []
        )
        let battery = BatteryReport(
            present: true,
            charging: false,
            externalConnected: true,
            currentCapacityPercent: 30,
            cycleCount: 200,
            designCapacityMah: 5000,
            maxCapacityMah: 5000,
            healthPercent: 100,
            temperatureCelsius: 48.0, // critically hot -> -15
            chargeLimitSupported: false,
            notes: []
        )
        let overrides = ActiveOverrides()

        let result = HealthScorer.calculateScore(
            sensors: sensors,
            battery: battery,
            activeOverrides: overrides,
            isKeepAwakeActive: false
        )

        // 100 - 60 - 15 = 25
        XCTAssertEqual(result.score, 25)
    }

    func testDurationParserValid() throws {
        XCTAssertEqual(try DurationParser.parse("500ms"), 0.5)
        XCTAssertEqual(try DurationParser.parse("2s"), 2.0)
        XCTAssertEqual(try DurationParser.parse("1.5s"), 1.5)
        XCTAssertEqual(try DurationParser.parse("5m"), 300.0)
        XCTAssertEqual(try DurationParser.parse("1h"), 3600.0)
        XCTAssertEqual(try DurationParser.parse("2"), 2.0)
        XCTAssertEqual(try DurationParser.parse("  2.5s  "), 2.5)
    }

    func testDurationParserInvalid() {
        XCTAssertThrowsError(try DurationParser.parse(""))
        XCTAssertThrowsError(try DurationParser.parse("abc"))
        XCTAssertThrowsError(try DurationParser.parse("2x"))
        XCTAssertThrowsError(try DurationParser.parse("ms"))
    }
}

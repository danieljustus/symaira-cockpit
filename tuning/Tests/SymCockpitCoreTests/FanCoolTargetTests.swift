import XCTest
@testable import SymCockpitCore

final class FanCoolTargetTests: XCTestCase {

    // MARK: - Fixtures

    private func report(_ rows: [(String, Double)]) -> SensorReport {
        SensorReport(
            thermalPressure: "nominal",
            smcSupported: true,
            temperatures: rows.map { SensorReading(key: $0.0, label: $0.0, celsius: $0.1) },
            fans: [],
            notes: []
        )
    }

    /// The live M4 Pro report described in the issue: hotspots, core rows (some
    /// missing), the core-max row, a proximity row and E-core clusters.
    private var m4ProReport: SensorReport {
        report([
            ("TCMz", 80), ("TRDX", 70), ("TCMb", 79),
            ("Tp01", 60), ("Tp02", 62), ("Tp03", 64),
            ("TCHP", 45),
            ("Te04", 50), ("Te05", 52),
        ])
    }

    // MARK: - Bounds

    func testRangeIsFiftyToEightyFive() {
        XCTAssertEqual(FanCoolTarget.range, 50...85)
    }

    func testSanitizedClampsAndDropsNonFiniteValues() {
        XCTAssertEqual(FanCoolTarget.sanitized(70), 70)
        XCTAssertEqual(FanCoolTarget.sanitized(10), 50)
        XCTAssertEqual(FanCoolTarget.sanitized(500), 85)
        XCTAssertEqual(FanCoolTarget.sanitized(-3), 50)
        XCTAssertNil(FanCoolTarget.sanitized(nil))
        XCTAssertNil(FanCoolTarget.sanitized(.nan))
        XCTAssertNil(FanCoolTarget.sanitized(.infinity))
        XCTAssertNil(FanCoolTarget.sanitized(-.infinity))
    }

    func testIsWithinRangeDoesNotClamp() {
        XCTAssertTrue(FanCoolTarget.isWithinRange(50))
        XCTAssertTrue(FanCoolTarget.isWithinRange(85))
        XCTAssertFalse(FanCoolTarget.isWithinRange(49.9))
        XCTAssertFalse(FanCoolTarget.isWithinRange(85.1))
        XCTAssertFalse(FanCoolTarget.isWithinRange(.nan))
    }

    func testSelectionClampsItsTargetAndOnlyCoolUsesIt() {
        XCTAssertEqual(FanSelection(profile: .comfort, coolTargetCelsius: 20).coolTargetCelsius, 50)
        XCTAssertEqual(FanSelection(profile: .comfort, coolTargetCelsius: 99).coolTargetCelsius, 85)
        XCTAssertEqual(FanSelection(profile: .comfort, coolTargetCelsius: 70).effectiveCoolTarget, 70)
        XCTAssertNil(FanSelection(profile: .performance, coolTargetCelsius: 70).effectiveCoolTarget)
        XCTAssertNil(FanSelection(profile: .system, coolTargetCelsius: 70).effectiveCoolTarget)
        XCTAssertEqual(
            FanSelection(profile: .performance, coolTargetCelsius: 70).coolTargetCelsius, 70,
            "the number is kept while another position is selected"
        )
    }

    // MARK: - Target curve

    // MARK: - Average cluster temperature

    // MARK: - Control law

    // MARK: - Governor decision

}

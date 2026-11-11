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

    func testTargetCurveReachesFullSpeedAtTheTarget() {
        for target in stride(from: 50.0, through: 85.0, by: 5.0) {
            let curve = FanCoolTarget.curve(target: target)
            XCTAssertEqual(curve.fraction(at: target), 1.0, accuracy: 1e-9)
            XCTAssertEqual(curve.fraction(at: target - 10), 0.78, accuracy: 1e-9)
            XCTAssertEqual(curve.fraction(at: target - 40), 0.30, accuracy: 1e-9)
            XCTAssertEqual(curve.points.count, 5)
        }
    }

    func testTargetCurveAtEightyFiveIsTheDefaultCoolCurve() throws {
        let cool = try XCTUnwrap(FanProfile.comfort.curve)
        let shifted = FanCoolTarget.curve(target: 85)
        for celsius in stride(from: 30.0, through: 100.0, by: 0.5) {
            XCTAssertEqual(shifted.fraction(at: celsius), cool.fraction(at: celsius), accuracy: 1e-9)
        }
    }

    func testTargetCurveSanitizesItsInput() {
        XCTAssertEqual(FanCoolTarget.curve(target: 500).points.last?.temperatureC, 85)
        XCTAssertEqual(FanCoolTarget.curve(target: 1).points.last?.temperatureC, 50)
    }

    // MARK: - Average cluster temperature

    func testAverageIsTheFlatMeanOfCpuAndGpuClusterRows() throws {
        let rows: [(String, Double)] = [
            ("Tp01", 60), ("Tp02", 70), ("Te04", 50), ("Tg0a", 80),
        ]
        let average = try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: report(rows)))
        XCTAssertEqual(average, 65, accuracy: 1e-9)
    }

    func testAverageExcludesHotspotAggregatesProximityAmbientAndUnknownRows() throws {
        let average = try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: m4ProReport))
        // Tp01–03, Te04–05 and the GPU's one reading TRDX (70):
        // (60+62+64+50+52+70) / 6. TCMz, TCMb and TCHP are not averaged.
        XCTAssertEqual(average, 358.0 / 6.0, accuracy: 1e-9)
    }

    func testAverageIgnoresImplausibleReadings() throws {
        // An M4 Pro reads Tp rows back at 0–8 °C; they must not drag the mean down.
        let rows: [(String, Double)] = [
            ("Tp01", 3), ("Tp02", 8), ("Tp03", 70), ("Te04", 130), ("Te05", .nan),
            ("Te06", 60),
        ]
        let average = try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: report(rows)))
        XCTAssertEqual(average, 65, accuracy: 1e-9)
    }

    func testAverageIncludesIntelCoreRowsButNotProximity() throws {
        let rows: [(String, Double)] = [
            ("TC0C", 60), ("TC1C", 70), ("TCXC", 80), ("TC0P", 30), ("TG0P", 70), ("TA0P", 25),
        ]
        let average = try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: report(rows)))
        XCTAssertEqual(average, 70, accuracy: 1e-9)
    }

    func testTheCpuHotspotStandsInOnlyWhenNoCpuClusterRowExists() throws {
        let hotspotsOnly = report([("TCMz", 80), ("TRDX", 60), ("TCMb", 90), ("TCHP", 40)])
        // TCMb (core max) is never used; TCMz only as the CPU fallback; TRDX is the GPU.
        XCTAssertEqual(
            try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: hotspotsOnly)), 70, accuracy: 1e-9
        )
        let withCluster = report([("TCMz", 99), ("Tp01", 60), ("TRDX", 70)])
        XCTAssertEqual(
            try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: withCluster)), 65, accuracy: 1e-9,
            "TCMz must not be averaged in beside real cluster rows"
        )
    }

    func testTheGpuOnlyMacStillHasAnAverage() throws {
        XCTAssertEqual(
            try XCTUnwrap(FanCoolTarget.averageClusterTemperature(in: report([("TRDX", 61), ("TCHP", 40)]))),
            61, accuracy: 1e-9
        )
    }

    func testAverageIsNilWithoutAQualifyingReading() {
        XCTAssertNil(FanCoolTarget.averageClusterTemperature(in: report([])))
        XCTAssertNil(FanCoolTarget.averageClusterTemperature(
            in: report([("TCHP", 45), ("Ta0P", 25), ("TM0P", 40), ("Ts0S", 50), ("TCMb", 80)])
        ))
        XCTAssertNil(FanCoolTarget.averageClusterTemperature(
            in: report([("Tp01", 2), ("Tp02", 5), ("TCMz", 200), ("TRDX", 3)])
        ), "only implausible cluster, hotspot and GPU readings")
    }

    // MARK: - Control law

    func testWithoutATargetTheLawIsTodaysCoolCurve() throws {
        let cool = try XCTUnwrap(FanProfile.comfort.curve)
        for celsius in stride(from: 20.0, through: 110.0, by: 1.0) {
            XCTAssertEqual(
                FanCoolTarget.targetFraction(
                    profile: .comfort, temperature: celsius, coolTarget: nil, averageTemperature: 90
                ),
                cool.fraction(at: celsius)
            )
        }
    }

    /// The safety property: across the whole grid, a target never produces less
    /// cooling than the default curve, whatever the average is.
    func testATargetNeverReducesCooling() throws {
        let cool = try XCTUnwrap(FanProfile.comfort.curve)
        for target in stride(from: 50.0, through: 85.0, by: 5.0) {
            for die in stride(from: 20.0, through: 110.0, by: 2.5) {
                for average in stride(from: 10.0, through: 120.0, by: 5.0) {
                    let fraction = try XCTUnwrap(FanCoolTarget.targetFraction(
                        profile: .comfort, temperature: die, coolTarget: target,
                        averageTemperature: average
                    ))
                    XCTAssertGreaterThanOrEqual(fraction, cool.fraction(at: die))
                    XCTAssertLessThanOrEqual(fraction, 1.0)
                }
            }
        }
    }

    func testAverageAtTheTargetRunsTheFansFlatOut() {
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .comfort, temperature: 40, coolTarget: 60, averageTemperature: 60
            ), 1.0
        )
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .comfort, temperature: 40, coolTarget: 60, averageTemperature: 75
            ), 1.0
        )
    }

    func testAnAverageWellBelowTheTargetAddsNothing() throws {
        let cool = try XCTUnwrap(FanProfile.comfort.curve)
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .comfort, temperature: 60, coolTarget: 80, averageTemperature: 30
            ), cool.fraction(at: 60)
        )
    }

    func testMissingAverageFallsBackToTheDefaultCurve() throws {
        let cool = try XCTUnwrap(FanProfile.comfort.curve)
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .comfort, temperature: 70, coolTarget: 50, averageTemperature: nil
            ), cool.fraction(at: 70)
        )
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .comfort, temperature: 70, coolTarget: 50, averageTemperature: .nan
            ), cool.fraction(at: 70)
        )
    }

    func testPerformanceIgnoresTheTarget() throws {
        let performance = try XCTUnwrap(FanProfile.performance.curve)
        XCTAssertEqual(
            FanCoolTarget.targetFraction(
                profile: .performance, temperature: 50, coolTarget: 50, averageTemperature: 90
            ), performance.fraction(at: 50)
        )
    }

    func testSystemHasNoFractionEvenWithATarget() {
        XCTAssertNil(FanCoolTarget.targetFraction(
            profile: .system, temperature: 90, coolTarget: 50, averageTemperature: 90
        ))
    }

    func testOutOfRangeTargetsAreClampedInTheLaw() {
        // 20 behaves exactly like 50, 500 exactly like 85.
        for average in stride(from: 30.0, through: 100.0, by: 5.0) {
            XCTAssertEqual(
                FanCoolTarget.targetFraction(profile: .comfort, temperature: 40, coolTarget: 20, averageTemperature: average),
                FanCoolTarget.targetFraction(profile: .comfort, temperature: 40, coolTarget: 50, averageTemperature: average)
            )
            XCTAssertEqual(
                FanCoolTarget.targetFraction(profile: .comfort, temperature: 40, coolTarget: 500, averageTemperature: average),
                FanCoolTarget.targetFraction(profile: .comfort, temperature: 40, coolTarget: 85, averageTemperature: average)
            )
        }
    }

    // MARK: - Governor decision

    func testNextFractionWithoutAverageEqualsTheLegacyOverload() {
        for applied in [nil, 0.3, 0.6, 1.0] as [Double?] {
            for temperature in stride(from: 30.0, through: 100.0, by: 5.0) {
                XCTAssertEqual(
                    FanGovernor.nextFraction(
                        selection: FanSelection(profile: .comfort, coolTargetCelsius: 60),
                        temperature: temperature, averageTemperature: nil, applied: applied
                    ),
                    FanGovernor.nextFraction(profile: .comfort, temperature: temperature, applied: applied)
                )
            }
        }
    }

    func testNextFractionRisesImmediatelyToTheTargetCurve() {
        let next = FanGovernor.nextFraction(
            selection: FanSelection(profile: .comfort, coolTargetCelsius: 60),
            temperature: 45, averageTemperature: 60, applied: 0.30
        )
        XCTAssertEqual(next ?? 0, 1.0, accuracy: 1e-9)
    }

    func testNextFractionStillFallsAtTheBoundedRateWhenTheAverageDrops() {
        let next = FanGovernor.nextFraction(
            selection: FanSelection(profile: .comfort, coolTargetCelsius: 60),
            temperature: 45, averageTemperature: 30, applied: 1.0
        )
        XCTAssertEqual(next ?? 0, 1.0 - FanGovernor.maxDecreasePerTick, accuracy: 1e-9)
    }

    func testNextFractionIgnoresTheTargetOutsideCool() {
        let withTarget = FanGovernor.nextFraction(
            selection: FanSelection(profile: .performance, coolTargetCelsius: 50),
            temperature: 50, averageTemperature: 90, applied: nil
        )
        let without = FanGovernor.nextFraction(profile: .performance, temperature: 50, applied: nil)
        XCTAssertEqual(withTarget, without)
        XCTAssertNil(FanGovernor.nextFraction(
            selection: FanSelection(profile: .system, coolTargetCelsius: 50),
            temperature: 90, averageTemperature: 90, applied: nil
        ))
    }

    func testNextFractionHoldsWhenThereIsNoGoverningTemperature() {
        XCTAssertEqual(
            FanGovernor.nextFraction(
                selection: FanSelection(profile: .comfort, coolTargetCelsius: 50),
                temperature: nil, averageTemperature: 90, applied: 0.7
            ), 0.7
        )
    }
}

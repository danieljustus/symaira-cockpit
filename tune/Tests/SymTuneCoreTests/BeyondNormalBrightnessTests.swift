import XCTest
@testable import SymTuneCore

final class BeyondNormalBrightnessTests: XCTestCase {

    private let config = TuneConfig()

    private func resolve(_ position: Double, edr: Bool = true) -> BeyondNormalBrightness {
        BeyondNormalBrightness.resolve(
            position: position,
            config: config,
            allowsExtendedBrightness: edr
        )
    }

    // MARK: - Centre

    func testCentreLeavesTheDisplayUntouched() {
        XCTAssertEqual(resolve(0), .normal)
        XCTAssertEqual(resolve(0).dimFactor, 1.0)
        XCTAssertEqual(resolve(0).extendedBrightness, 1.0)
    }

    // MARK: - Left of centre

    func testFullLeftReachesTheDimFloorAndNoFurther() {
        XCTAssertEqual(resolve(-1).dimFactor, config.dimMin, accuracy: 0.0001)
    }

    func testLeftOfCentreDimsProportionally() {
        // Half way to the floor from 1.0.
        let expected = 1.0 - 0.5 * (1.0 - config.dimMin)
        XCTAssertEqual(resolve(-0.5).dimFactor, expected, accuracy: 0.0001)
    }

    func testDimmingNeverBlacksTheScreenOut() {
        for position in stride(from: -1.0, through: 0.0, by: 0.1) {
            XCTAssertGreaterThanOrEqual(resolve(position).dimFactor, config.dimMin)
        }
    }

    /// Moving left must clear any EDR headroom, or the right half keeps acting
    /// invisibly while the knob claims the display is being dimmed.
    func testMovingLeftClearsExtendedBrightness() {
        XCTAssertEqual(resolve(-0.7).extendedBrightness, 1.0)
    }

    // MARK: - Right of centre

    func testFullRightReachesTheExtendedBrightnessCeilingAndNoFurther() {
        XCTAssertEqual(
            resolve(1).extendedBrightness,
            config.extendedBrightnessMax,
            accuracy: 0.0001
        )
    }

    func testRightOfCentreRaisesHeadroomProportionally() {
        let expected = 1.0 + 0.5 * (config.extendedBrightnessMax - 1.0)
        XCTAssertEqual(resolve(0.5).extendedBrightness, expected, accuracy: 0.0001)
    }

    func testMovingRightLiftsTheDimOverlay() {
        XCTAssertEqual(resolve(0.7).dimFactor, 1.0)
    }

    /// A display with no EDR headroom cannot go brighter than normal, so the
    /// positive half must resolve to "no change" rather than a rejected write.
    func testPositiveHalfIsInertWithoutEDRSupport() {
        XCTAssertEqual(resolve(0.9, edr: false), .normal)
        XCTAssertEqual(resolve(-0.9, edr: false).dimFactor, resolve(-0.9).dimFactor)
    }

    // MARK: - Clamping

    func testPositionsBeyondTheRangeClampRatherThanOvershoot() {
        XCTAssertEqual(resolve(-4).dimFactor, resolve(-1).dimFactor)
        XCTAssertEqual(resolve(4).extendedBrightness, resolve(1).extendedBrightness)
    }

    func testResolvedValuesAlwaysSitInsideTheConfiguredBounds() {
        for position in stride(from: -1.0, through: 1.0, by: 0.05) {
            let result = resolve(position)
            XCTAssertGreaterThanOrEqual(result.dimFactor, config.dimMin)
            XCTAssertLessThanOrEqual(result.dimFactor, config.dimMax)
            XCTAssertLessThanOrEqual(result.extendedBrightness, config.extendedBrightnessMax)
            XCTAssertGreaterThanOrEqual(result.extendedBrightness, 1.0)
        }
    }

    // MARK: - Round trip

    func testPositionRoundTripsThroughResolve() {
        for original in stride(from: -1.0, through: 1.0, by: 0.1) {
            let resolved = resolve(original)
            let recovered = BeyondNormalBrightness.position(
                dimFactor: resolved.dimFactor,
                extendedBrightness: resolved.extendedBrightness,
                config: config
            )
            XCTAssertEqual(recovered, original, accuracy: 0.0001, "position \(original)")
        }
    }

    func testNoOverridesSeedsTheKnobAtCentre() {
        XCTAssertEqual(
            BeyondNormalBrightness.position(
                dimFactor: nil,
                extendedBrightness: nil,
                config: config
            ),
            0
        )
    }

    func testDimTakesPrecedenceWhenBothOverridesAreSomehowActive() {
        let position = BeyondNormalBrightness.position(
            dimFactor: 0.5,
            extendedBrightness: 1.4,
            config: config
        )
        XCTAssertLessThan(position, 0)
    }

    // MARK: - Readout

    func testReadoutNamesTheSideOfCentre() {
        XCTAssertEqual(BeyondNormalBrightness.readout(position: 0), "Normal")
        XCTAssertEqual(BeyondNormalBrightness.readout(position: -0.4), "Dim 40%")
        XCTAssertEqual(BeyondNormalBrightness.readout(position: 0.25), "Bright +25%")
    }

    func testReadoutTreatsNearCentreAsNormal() {
        XCTAssertEqual(BeyondNormalBrightness.readout(position: 0.001), "Normal")
    }
}

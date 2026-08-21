import XCTest
@testable import SymTuneCore

/// Regression test for issue #175: verify the view's dim-amount-to-multiplier mapping.
///
/// The view drives a Slider over 0.0…0.85 as a "dim amount" and passes `1.0 - dim`
/// into `TuneController.applyDim`, which expects a brightness multiplier (1.0 = no dim,
/// dimMin = darkest). This test pins the conversion at both ends of the range.
final class DimAmountMappingTests: XCTestCase {

    // MARK: - View boundary conversion

    func testViewZeroPercentMapsToCoreNoDim() throws {
        // Arrange: view dim amount = 0% (no dimming desired)
        let dimAmount = 0.0
        let coreMultiplier = 1.0 - dimAmount

        // Act: pass the converted multiplier to the controller
        let controller = TuneController(config: TuneConfig())
        try controller.applyDim(coreMultiplier)

        // Assert: core reports multiplier = 1.0 (no dim)
        XCTAssertEqual(controller.getDimLevel(), 1.0, accuracy: 0.001,
                       "View 0% must map to core multiplier 1.0 (no dim)")
    }

    func testSliderMaximumMapsToCoreDimMin() throws {
        // Arrange: view slider maximum = 85% dim amount
        let dimAmount = 0.85
        let coreMultiplier = 1.0 - dimAmount

        // Act: pass the converted multiplier to the controller
        let controller = TuneController(config: TuneConfig())
        try controller.applyDim(coreMultiplier)

        // Assert: core reports multiplier = dimMin (darkest allowed)
        XCTAssertEqual(controller.getDimLevel(), SafetyPolicy.dimMin, accuracy: 0.001,
                       "View max (0.85) must map to core dimMin (darkest setting)")
    }

    // MARK: - Read-path: convert core multiplier back to dim amount

    func testReadPathConvertsMultiplierToDimAmount() {
        // Arrange: controller has no dim applied (multiplier = 1.0)
        let controller = TuneController(config: TuneConfig())

        // Act: read core level and convert back to dim amount
        let dimAmount = 1.0 - controller.getDimLevel()

        // Assert: dim amount should be 0% (no dim)
        XCTAssertEqual(dimAmount, 0.0, accuracy: 0.001,
                       "Core multiplier 1.0 must convert to view dim amount 0.0")
    }

    func testReadPathAfterApplyingMaxDim() throws {
        // Arrange: apply darkest allowed dim (core multiplier = dimMin)
        let controller = TuneController(config: TuneConfig())
        try controller.applyDim(SafetyPolicy.dimMin)

        // Act: read core level and convert to dim amount
        let dimAmount = 1.0 - controller.getDimLevel()

        // Assert: dim amount should be 0.85 (view maximum)
        XCTAssertEqual(dimAmount, 0.85, accuracy: 0.001,
                       "Core dimMin must convert to view dim amount 0.85")
    }

    // MARK: - Round-trip invariance

    func testRoundTripAtZero() throws {
        let controller = TuneController(config: TuneConfig())

        // Write: view dim 0% → core multiplier 1.0
        try controller.applyDim(1.0 - 0.0)
        // Read: core multiplier → view dim amount
        let readback = 1.0 - controller.getDimLevel()

        XCTAssertEqual(readback, 0.0, accuracy: 0.001,
                       "Round-trip at 0% must return 0.0")
    }

    func testRoundTripAtMaximum() throws {
        let controller = TuneController(config: TuneConfig())

        // Write: view dim max (0.85) → core multiplier 1.0 - 0.85 = 0.15 = dimMin
        try controller.applyDim(1.0 - 0.85)
        // Read: core dimMin → view dim amount 1.0 - 0.15 = 0.85
        let readback = 1.0 - controller.getDimLevel()

        XCTAssertEqual(readback, 0.85, accuracy: 0.001,
                       "Round-trip at maximum must return 0.85")
    }

    func testRoundTripAtMidpoint() throws {
        let controller = TuneController(config: TuneConfig())

        // View dim 42.5% → core 1.0 - 0.425 = 0.575
        let viewValue = 0.425
        try controller.applyDim(1.0 - viewValue)
        let readback = 1.0 - controller.getDimLevel()

        XCTAssertEqual(readback, viewValue, accuracy: 0.001,
                       "Round-trip at midpoint must be identity")
    }
}

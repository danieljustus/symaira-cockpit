import XCTest
@testable import SymTuneCore

/// The brightness-key preference and the step arithmetic behind one press
/// (issue #250).
///
/// Taking over a hardware key has two rules worth pinning: it never happens
/// unless it was asked for, and a press has to land where the system's own
/// press would have landed.
final class BrightnessKeysTests: XCTestCase {

    // MARK: - Preference

    func testDefaultsToTheSystemWhenNothingIsStored() {
        XCTAssertEqual(BrightnessKeyDefaults.resolve(storedHandling: nil), .system)
    }

    func testUnrecognisedStoredValueLeavesTheKeysAlone() {
        // A value from a future build, or a hand-edited plist: the safe reading
        // of "I do not understand this" is not "intercept the keyboard".
        XCTAssertEqual(BrightnessKeyDefaults.resolve(storedHandling: "wat"), .system)
        XCTAssertEqual(BrightnessKeyDefaults.resolve(storedHandling: ""), .system)
    }

    func testStoredPreferenceIsHonoured() {
        XCTAssertEqual(BrightnessKeyDefaults.resolve(storedHandling: "cockpit"), .cockpit)
        XCTAssertEqual(BrightnessKeyDefaults.resolve(storedHandling: "system"), .system)
    }

    func testRawValuesAreStableAcrossLaunches() {
        // On disk in the grandfathered defaults namespace; renaming a case
        // would silently reset the preference for everyone who set it.
        XCTAssertEqual(BrightnessKeyHandling.system.rawValue, "system")
        XCTAssertEqual(BrightnessKeyHandling.cockpit.rawValue, "cockpit")
    }

    // MARK: - Stepping

    func testAPressMovesOneSixteenth() {
        XCTAssertEqual(
            BrightnessKeyStep.next(from: 0.5, direction: .up, fine: false),
            0.5 + 1.0 / 16.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BrightnessKeyStep.next(from: 0.5, direction: .down, fine: false),
            0.5 - 1.0 / 16.0,
            accuracy: 0.0001
        )
    }

    func testShiftOptionQuartersTheStep() {
        XCTAssertEqual(
            BrightnessKeyStep.next(from: 0.5, direction: .up, fine: true),
            0.5 + 1.0 / 64.0,
            accuracy: 0.0001
        )
    }

    func testAnOffGridLevelSnapsOntoTheGridAsItSteps() {
        // 0.40 sits between 6/16 (0.375) and 7/16 (0.4375). A press up must
        // land on 7/16 exactly, not on 0.4625 — otherwise the offset is carried
        // for every press that follows.
        XCTAssertEqual(
            BrightnessKeyStep.next(from: 0.40, direction: .up, fine: false),
            7.0 / 16.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BrightnessKeyStep.next(from: 0.40, direction: .down, fine: false),
            5.0 / 16.0,
            accuracy: 0.0001
        )
    }

    func testSteppingStopsAtTheEnds() {
        XCTAssertEqual(BrightnessKeyStep.next(from: 1.0, direction: .up, fine: false), 1.0)
        XCTAssertEqual(BrightnessKeyStep.next(from: 0.0, direction: .down, fine: false), 0.0)
    }

    func testOutOfRangeInputIsClampedBeforeStepping() {
        // The display API is private; a nonsense read must not become a
        // nonsense write.
        XCTAssertEqual(BrightnessKeyStep.next(from: 4.2, direction: .up, fine: false), 1.0)
        XCTAssertEqual(BrightnessKeyStep.next(from: -3, direction: .down, fine: false), 0.0)
    }

    func testSixteenPressesCrossTheWholeRange() {
        // The step grid has to actually reach both ends, or the last press
        // before the end does nothing visible.
        var level: Float = 0
        for _ in 0 ..< 16 {
            level = BrightnessKeyStep.next(from: level, direction: .up, fine: false)
        }
        XCTAssertEqual(level, 1.0, accuracy: 0.0001)
    }

    // MARK: - HUD bar

    func testSegmentsFillProportionally() {
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: 0, of: 16), 0)
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: 0.5, of: 16), 8)
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: 1, of: 16), 16)
    }

    func testSegmentsNeverOverrunTheBar() {
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: 9.9, of: 16), 16)
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: -1, of: 16), 0)
        XCTAssertEqual(BrightnessKeyStep.filledSegments(for: 0.5, of: 0), 0)
    }
}

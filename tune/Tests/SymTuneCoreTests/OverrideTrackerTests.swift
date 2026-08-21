import XCTest
@testable import SymTuneCore

final class OverrideTrackerTests: XCTestCase {

    func testAppliedEDRBrightness() {
        let tracker = OverrideTracker()
        XCTAssertNil(tracker.appliedEDRBrightness)
        XCTAssertFalse(tracker.hasEDROverride())

        tracker.saveEDRBrightness(1.4)
        XCTAssertEqual(tracker.appliedEDRBrightness, 1.4)
        XCTAssertTrue(tracker.hasEDROverride())
    }

    func testHasWarmthOverride() {
        let tracker = OverrideTracker()
        XCTAssertFalse(tracker.hasWarmthOverride())

        tracker.saveWarmth(0.3)
        XCTAssertTrue(tracker.hasWarmthOverride())
        XCTAssertEqual(tracker.currentWarmth, 0.3)
    }

    func testRestoreAllClearsAllOverrides() {
        var onRestoreCalled = false
        let tracker = OverrideTracker(onRestore: { onRestoreCalled = true })

        tracker.saveBrightness(0.6)
        tracker.saveWarmth(0.4)
        tracker.saveEDRBrightness(1.2)

        XCTAssertTrue(tracker.hasBrightnessOverride())
        XCTAssertTrue(tracker.hasWarmthOverride())
        XCTAssertTrue(tracker.hasEDROverride())
        XCTAssertEqual(tracker.appliedEDRBrightness, 1.2)

        tracker.restoreAll()

        XCTAssertFalse(tracker.hasBrightnessOverride())
        XCTAssertFalse(tracker.hasWarmthOverride())
        XCTAssertFalse(tracker.hasEDROverride())
        XCTAssertNil(tracker.appliedEDRBrightness)
        XCTAssertTrue(onRestoreCalled)
    }

    func testRestoreBrightnessWithoutDisplayService() {
        let tracker = OverrideTracker(displayService: nil)
        tracker.saveBrightness(0.5)
        tracker.restoreAll()
        XCTAssertFalse(tracker.hasBrightnessOverride())
    }

    func testRegisterSignalHandlers() {
        let tracker = OverrideTracker()
        tracker.registerSignalHandlers()
    }
}

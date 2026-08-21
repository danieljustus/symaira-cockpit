import XCTest
@testable import SymTuneCore

/// In-memory gamma hardware with a non-identity base ramp, so "did we keep the
/// display's own calibration?" is actually observable.
private final class RecordingGammaIO: GammaIO, @unchecked Sendable {
    /// A deliberately curved base ramp — a real display's calibration is not
    /// the identity, and the old warmth path replaced it with a linear one.
    static func curvedRamp(sampleCount: Int = 256) -> GammaRamp {
        let values = (0..<sampleCount).map { index -> CGGammaValue in
            let normalized = Float(index) / Float(sampleCount - 1)
            return pow(normalized, 1.2)
        }
        return GammaRamp(red: values, green: values, blue: values)
    }

    private let lock = NSLock()
    var base: GammaRamp = RecordingGammaIO.curvedRamp()
    var readFailure = false
    var writeFailure = false
    private(set) var writes: [(displayID: CGDirectDisplayID, ramp: GammaRamp)] = []
    private(set) var restoreCount = 0
    private(set) var readCount = 0

    func readRamp(displayID: CGDirectDisplayID, sampleCount: Int) -> GammaRamp? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return readFailure ? nil : base
    }

    func writeRamp(_ ramp: GammaRamp, displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !writeFailure else { return false }
        writes.append((displayID, ramp))
        return true
    }

    func restoreSystemRamps() {
        lock.lock(); restoreCount += 1; lock.unlock()
    }

    var lastRamp: GammaRamp? {
        lock.lock(); defer { lock.unlock() }
        return writes.last?.ramp
    }
}

final class GammaCompositionTests: XCTestCase {

    func testNeutralInputReproducesTheBaseRampExactly() throws {
        let base = RecordingGammaIO.curvedRamp()
        let composed = try XCTUnwrap(GammaComposition.compose(base: base, warmth: 0, boost: 1.0))
        XCTAssertEqual(composed, base, "neutral must mean 'the display untouched'")
    }

    func testBoostScalesEveryChannelAboveOne() throws {
        let base = GammaRamp.identity()
        let composed = try XCTUnwrap(GammaComposition.compose(base: base, warmth: 0, boost: 1.5))

        // The old code clamped the table to 1.0, which is exactly why the
        // slider above "Normal" did nothing at all.
        XCTAssertEqual(try XCTUnwrap(composed.red.last), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composed.green.last), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composed.blue.last), 1.5, accuracy: 0.0001)
        XCTAssertEqual(composed.red[128], base.red[128] * 1.5, accuracy: 0.0001)
    }

    func testWarmthPullsBlueDownHardestAndLeavesRedAlone() throws {
        let base = GammaRamp.identity()
        let composed = try XCTUnwrap(GammaComposition.compose(base: base, warmth: 1.0, boost: 1.0))

        XCTAssertEqual(try XCTUnwrap(composed.red.last), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composed.green.last),
                       1.0 - GammaComposition.warmthGreenAttenuation, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composed.blue.last),
                       1.0 - GammaComposition.warmthBlueAttenuation, accuracy: 0.0001)
    }

    func testWarmthAndBoostCombineInOneTable() throws {
        let base = GammaRamp.identity()
        let composed = try XCTUnwrap(GammaComposition.compose(base: base, warmth: 0.5, boost: 1.4))

        XCTAssertEqual(try XCTUnwrap(composed.red.last), 1.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composed.blue.last),
                       1.4 * (1 - 0.5 * GammaComposition.warmthBlueAttenuation), accuracy: 0.0001)
    }

    func testValuesAreClampedToTheBoostCeiling() throws {
        // A base ramp that already reaches 1.0 must not exceed the ceiling.
        let base = GammaRamp.identity()
        let composed = try XCTUnwrap(GammaComposition.compose(base: base, warmth: 0, boost: 1.0))
        XCTAssertLessThanOrEqual(try XCTUnwrap(composed.red.max()), 1.0)
    }

    func testMalformedBaseIsRejected() {
        let ragged = GammaRamp(red: [0, 1], green: [0], blue: [0, 1])
        XCTAssertNil(GammaComposition.compose(base: ragged, warmth: 0, boost: 1.2))
        XCTAssertNil(GammaComposition.compose(base: GammaRamp(red: [], green: [], blue: []),
                                             warmth: 0, boost: 1.2))
    }

    func testNeutralDetection() {
        XCTAssertTrue(GammaComposition.isNeutral(warmth: 0, boost: 1.0))
        XCTAssertFalse(GammaComposition.isNeutral(warmth: 0.2, boost: 1.0))
        XCTAssertFalse(GammaComposition.isNeutral(warmth: 0, boost: 1.1))
    }
}

final class DisplayGammaControllerTests: XCTestCase {

    private let display: CGDirectDisplayID = 0x2000_0001
    private let otherDisplay: CGDirectDisplayID = 0x2000_0002

    func testWarmthAndBoostShareOneTableInsteadOfOverwritingEachOther() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)

        try controller.setBoost(1.4, displayID: display)
        try controller.setWarmth(1.0, displayID: display)

        XCTAssertEqual(controller.boost(for: display), 1.4, accuracy: 0.0001,
                       "setting warmth must not cancel the boost")
        XCTAssertEqual(controller.warmth(for: display), 1.0, accuracy: 0.0001)

        let ramp = try XCTUnwrap(io.lastRamp)
        let baseTail = try XCTUnwrap(io.base.red.last)
        XCTAssertEqual(try XCTUnwrap(ramp.red.last), baseTail * 1.4, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(ramp.blue.last),
            baseTail * 1.4 * (1 - GammaComposition.warmthBlueAttenuation),
            accuracy: 0.001
        )
    }

    func testBaseRampIsCapturedOnceAndReused() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)

        try controller.setWarmth(0.3, displayID: display)
        try controller.setWarmth(0.6, displayID: display)
        try controller.setBoost(1.2, displayID: display)

        XCTAssertEqual(io.readCount, 1,
                       "re-reading would capture our own modified table as the base")
    }

    func testReturningToNeutralRestoresTheSystemTable() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)

        try controller.setWarmth(0.5, displayID: display)
        XCTAssertTrue(controller.hasOverrides)

        try controller.setWarmth(0, displayID: display)

        XCTAssertFalse(controller.hasOverrides)
        XCTAssertEqual(io.restoreCount, 1)
        XCTAssertEqual(controller.warmth(for: display), 0, accuracy: 0.0001)

        // And the base is captured afresh next time, since the display has been
        // handed back to ColorSync in the meantime.
        try controller.setWarmth(0.2, displayID: display)
        XCTAssertEqual(io.readCount, 2)
    }

    func testResettingOneDisplayKeepsTheOtherDisplaysOverride() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)
        try controller.setBoost(1.3, displayID: display)
        try controller.setBoost(1.5, displayID: otherDisplay)

        controller.reset(displayID: display)

        // `CGDisplayRestoreColorSyncSettings` clears every display, so the
        // survivor has to be re-applied rather than silently dropped.
        XCTAssertEqual(io.restoreCount, 1)
        XCTAssertEqual(controller.boost(for: display), 1.0, accuracy: 0.0001)
        XCTAssertEqual(controller.boost(for: otherDisplay), 1.5, accuracy: 0.0001)
        let lastWrite = try XCTUnwrap(io.writes.last)
        XCTAssertEqual(lastWrite.displayID, otherDisplay)
    }

    func testReassertRewritesWithoutRecapturingTheBase() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)
        try controller.setBoost(1.25, displayID: display)
        let writesBefore = io.writes.count

        controller.reassert()

        XCTAssertEqual(io.writes.count, writesBefore + 1)
        XCTAssertEqual(io.readCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(io.lastRamp?.red.last),
            try XCTUnwrap(io.base.red.last) * 1.25,
            accuracy: 0.001
        )
    }

    func testUnreadableGammaTableSurfacesAsAnError() {
        let io = RecordingGammaIO()
        io.readFailure = true
        let controller = DisplayGammaController(io: io)

        XCTAssertThrowsError(try controller.setBoost(1.3, displayID: display)) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
        }
        XCTAssertFalse(controller.hasOverrides)
    }

    func testRejectedWriteSurfacesAsAnErrorAndKeepsNoPhantomOverride() {
        let io = RecordingGammaIO()
        io.writeFailure = true
        let controller = DisplayGammaController(io: io)

        XCTAssertThrowsError(try controller.setWarmth(0.4, displayID: display)) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
        }
        // A rejected write must not leave a recorded override behind, or the
        // readout would claim a shift the display never got.
        XCTAssertEqual(controller.warmth(for: display), 0, accuracy: 0.0001)
        XCTAssertFalse(controller.hasOverrides)
    }

    func testRejectedWriteKeepsTheValueThatIsStillOnTheDisplay() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)
        try controller.setBoost(1.3, displayID: display)

        io.writeFailure = true
        XCTAssertThrowsError(try controller.setBoost(1.5, displayID: display))

        XCTAssertEqual(controller.boost(for: display), 1.3, accuracy: 0.0001,
                       "the failed change must not overwrite the applied one")
    }

    func testBoostBelowOneIsTreatedAsNeutral() throws {
        let io = RecordingGammaIO()
        let controller = DisplayGammaController(io: io)

        // Dimming is the dim overlay's job; the gamma boost only goes up.
        try controller.setBoost(0.5, displayID: display)

        XCTAssertEqual(controller.boost(for: display), 1.0, accuracy: 0.0001)
        XCTAssertFalse(controller.hasOverrides)
    }
}

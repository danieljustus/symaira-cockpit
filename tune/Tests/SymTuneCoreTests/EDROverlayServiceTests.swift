import XCTest
import QuartzCore
@testable import SymTuneCore

/// Records trigger lifecycle without creating real windows or Metal devices.
private final class FakeTrigger: EDRTriggering, @unchecked Sendable {
    private let lock = NSLock()
    private var _renderCount = 0
    private var _removed = false

    var renderCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _renderCount
    }

    var removed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _removed
    }

    func render() {
        lock.lock(); _renderCount += 1; lock.unlock()
    }

    func remove() {
        lock.lock(); _removed = true; lock.unlock()
    }
}

/// In-memory gamma hardware.
private final class FakeGammaIO: GammaIO, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var written: [CGDirectDisplayID: GammaRamp] = [:]
    private(set) var restoreCount = 0
    var failWrites = false

    func readRamp(displayID: CGDirectDisplayID, sampleCount: Int) -> GammaRamp? {
        GammaRamp.identity(sampleCount: sampleCount)
    }

    func writeRamp(_ ramp: GammaRamp, displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failWrites else { return false }
        written[displayID] = ramp
        return true
    }

    func restoreSystemRamps() {
        lock.lock(); restoreCount += 1; written.removeAll(); lock.unlock()
    }

    /// Clear the write log so a test can assert that *no further* writes happen.
    func forgetWrites() {
        lock.lock(); written.removeAll(); lock.unlock()
    }
}

final class EDROverlayServiceTests: XCTestCase {

    private let displayA: CGDirectDisplayID = 0x1000_0001
    private let displayB: CGDirectDisplayID = 0x1000_0002

    /// A service under test with its fake hardware.
    private struct Fixture {
        let service: EDROverlayService
        let io: FakeGammaIO
        /// Triggers created so far — a closure because the factory appends.
        let triggers: () -> [FakeTrigger]
    }

    /// Service whose displays report `headroom`, with fake triggers and gamma.
    private func makeService(
        headroom: Double?,
        headroomByDisplay: [CGDirectDisplayID: Double] = [:]
    ) -> Fixture {
        let io = FakeGammaIO()
        let gamma = DisplayGammaController(io: io)
        nonisolated(unsafe) var created: [FakeTrigger] = []
        let service = EDROverlayService(
            gamma: gamma,
            headroomProvider: { headroomByDisplay[$0] ?? headroom },
            triggerFactory: { _ in
                let trigger = FakeTrigger()
                created.append(trigger)
                return trigger
            }
        )
        return Fixture(service: service, io: io, triggers: { created })
    }

    // MARK: - Engaged path

    func testApplyWritesGammaBoostWhenHeadroomIsGranted() throws {
        let fixture = makeService(headroom: 1.6)

        try fixture.service.applyExtendedBrightness(1.4, displayID: displayA)

        XCTAssertEqual(fixture.triggers().count, 1, "a trigger must be on screen to request EDR")
        XCTAssertGreaterThan(fixture.triggers().first?.renderCount ?? 0, 0, "the trigger must present a frame")
        XCTAssertEqual(try XCTUnwrap(fixture.service.currentHeadroom(for: displayA)), 1.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fixture.service.engagedBrightness(for: displayA)), 1.4, accuracy: 0.0001)
        XCTAssertEqual(fixture.service.brightnessMode(for: displayA), .extendedRange)

        // The boost has to reach the hardware, i.e. a scaled ramp is written.
        let ramp = try XCTUnwrap(fixture.io.written[displayA])
        XCTAssertEqual(try XCTUnwrap(ramp.red.last), 1.4, accuracy: 0.001)
    }

    func testBoostIsClampedToTheHeadroomTheDisplayGrants() throws {
        let fixture = makeService(headroom: 1.2)

        try fixture.service.applyExtendedBrightness(1.6, displayID: displayA)

        XCTAssertEqual(try XCTUnwrap(fixture.service.currentHeadroom(for: displayA)), 1.6, accuracy: 0.0001,
                       "the request is remembered as-is")
        XCTAssertEqual(try XCTUnwrap(fixture.service.engagedBrightness(for: displayA)), 1.2, accuracy: 0.0001,
                       "but only the granted headroom is applied")
        let ramp = try XCTUnwrap(fixture.io.written[displayA])
        XCTAssertEqual(try XCTUnwrap(ramp.red.last), 1.2, accuracy: 0.001)
    }

    func testApplyUpdatesExistingTriggerInsteadOfCreatingAnother() throws {
        let fixture = makeService(headroom: 1.6)

        try fixture.service.applyExtendedBrightness(1.3, displayID: displayA)
        try fixture.service.applyExtendedBrightness(1.5, displayID: displayA)

        XCTAssertEqual(fixture.triggers().count, 1)
        XCTAssertEqual(try XCTUnwrap(fixture.io.written[displayA].flatMap(\.red.last)), 1.5, accuracy: 0.001)
    }

    // MARK: - Not-yet-engaged path

    func testWithoutHeadroomTheLiftIsCappedAndReportedAsSoftware() throws {
        let fixture = makeService(headroom: 1.0)

        try fixture.service.applyExtendedBrightness(1.5, displayID: displayA)

        XCTAssertEqual(fixture.triggers().count, 1, "the trigger still goes up — that is what engages EDR")
        XCTAssertEqual(fixture.service.currentHeadroom(for: displayA), 1.5, "the request is remembered")
        XCTAssertEqual(fixture.service.brightnessMode(for: displayA), .softwareLift)
        // Above the cap the highlights would just clip, so the fallback stops there.
        XCTAssertEqual(
            try XCTUnwrap(fixture.service.engagedBrightness(for: displayA)),
            EDROverlayService.softwareBoostCap,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(fixture.io.written[displayA].flatMap(\.red.last))),
            EDROverlayService.softwareBoostCap,
            accuracy: 0.001
        )
    }

    func testASmallRequestIsHonouredInFullEvenWithoutHeadroom() throws {
        let fixture = makeService(headroom: 1.0)

        try fixture.service.applyExtendedBrightness(1.08, displayID: displayA)

        XCTAssertEqual(try XCTUnwrap(fixture.service.engagedBrightness(for: displayA)), 1.08, accuracy: 0.0001)
    }

    func testHeadroomAppearingUpgradesTheLiftToTheFullRequest() throws {
        nonisolated(unsafe) var headroom = 1.0
        let io = FakeGammaIO()
        let service = EDROverlayService(
            gamma: DisplayGammaController(io: io),
            headroomProvider: { _ in headroom },
            triggerFactory: { _ in FakeTrigger() }
        )
        try service.applyExtendedBrightness(1.5, displayID: displayA)
        XCTAssertEqual(service.brightnessMode(for: displayA), .softwareLift)

        // The display engages EDR; the next apply/reassert must take the full value.
        headroom = 1.6
        service.reassert()

        XCTAssertEqual(service.brightnessMode(for: displayA), .extendedRange)
        XCTAssertEqual(try XCTUnwrap(service.engagedBrightness(for: displayA)), 1.5, accuracy: 0.0001)
    }

    /// macOS does not grant the full headroom at once — it ramps up over a
    /// second or two after EDR engages. The boost has to follow, or a request
    /// for +45% stays stuck at whatever was available in the first instant.
    func testBoostFollowsHeadroomAsTheSystemRampsItUp() throws {
        nonisolated(unsafe) var granted = 1.2
        let io = FakeGammaIO()
        let service = EDROverlayService(
            gamma: DisplayGammaController(io: io),
            headroomProvider: { _ in granted },
            triggerFactory: { _ in FakeTrigger() }
        )

        try service.applyExtendedBrightness(1.45, displayID: displayA)
        XCTAssertEqual(try XCTUnwrap(service.engagedBrightness(for: displayA)), 1.2, accuracy: 0.0001,
                       "clamped to the headroom available at apply time")

        // The panel opens up while the watch is running. Spin the run loop so
        // the watch task gets scheduled; no expectation, to keep the test free
        // of non-Sendable captures.
        granted = 2.0
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let applied = service.engagedBrightness(for: displayA), applied >= 1.45 - 0.001 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertEqual(try XCTUnwrap(service.engagedBrightness(for: displayA)), 1.45, accuracy: 0.001,
                       "the watch must re-apply as the granted headroom grows")
        XCTAssertEqual(try XCTUnwrap(io.written[displayA].flatMap(\.red.last)), 1.45, accuracy: 0.001)
        service.removeAllOverlays()
    }

    // MARK: - Concurrent apply

    /// Building a trigger creates a window, so it happens outside the state
    /// lock — which makes the install a check-then-act. Two applies for one
    /// display can therefore both build a trigger, and the loser's 1×1 EDR
    /// window would otherwise stay on screen for the rest of the session,
    /// holding the display in HDR mode with nothing tracking it.
    ///
    /// The factory seam reproduces that interleaving deterministically: the
    /// first factory call re-enters `applyExtendedBrightness`, so the inner call
    /// installs its target first and the outer call arrives as the loser.
    func testALosingConcurrentApplyTakesItsTriggerBackOffScreen() throws {
        let io = FakeGammaIO()
        nonisolated(unsafe) var created: [FakeTrigger] = []
        nonisolated(unsafe) var service: EDROverlayService?
        nonisolated(unsafe) var reentered = false

        // Local copy: the factory closure is @Sendable and must not capture the
        // (non-Sendable) test case itself.
        let target = displayA
        service = EDROverlayService(
            gamma: DisplayGammaController(io: io),
            headroomProvider: { _ in 1.6 },
            triggerFactory: { displayID in
                let trigger = FakeTrigger()
                created.append(trigger)
                if !reentered, displayID == target {
                    reentered = true
                    // The competing apply lands while the outer one is still
                    // building its trigger.
                    try? service?.applyExtendedBrightness(1.3, displayID: target)
                }
                return trigger
            }
        )
        let subject = try XCTUnwrap(service)

        try subject.applyExtendedBrightness(1.5, displayID: displayA)

        XCTAssertEqual(created.count, 2, "both applies built a trigger — that is the race")
        XCTAssertEqual(created.filter(\.removed).count, 1, "exactly the loser is taken off screen")
        XCTAssertFalse(created.first?.removed == false && created.last?.removed == false,
                       "a surviving orphan trigger would keep requesting EDR forever")
        // The last writer's request wins and is what gets applied.
        XCTAssertEqual(try XCTUnwrap(subject.currentHeadroom(for: displayA)), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(subject.engagedBrightness(for: displayA)), 1.5, accuracy: 0.0001)

        subject.removeAllOverlays()
        XCTAssertTrue(created.allSatisfy(\.removed), "teardown leaves nothing on screen")
    }

    // MARK: - Headroom watch lifecycle

    /// A second apply while the watch is already running must not start a
    /// competing watch — two tasks would fight over the same gamma table.
    ///
    /// Also covers the steady state on a display that never grants headroom:
    /// the watch keeps polling for its window, and the capped software lift must
    /// stay exactly where it is instead of oscillating or climbing.
    func testASecondApplyReusesTheRunningHeadroomWatchAndTheLiftHoldsSteady() throws {
        let fixture = makeService(headroom: 1.0)

        try fixture.service.applyExtendedBrightness(1.5, displayID: displayA)
        try fixture.service.applyExtendedBrightness(1.4, displayID: displayA)

        XCTAssertEqual(fixture.triggers().count, 1, "the display keeps its single trigger")
        XCTAssertEqual(fixture.service.brightnessMode(for: displayA), .softwareLift)

        // Wait for the watch to have polled at least twice while the display
        // keeps refusing EDR. Condition-based rather than a fixed sleep: a
        // loaded machine may tick slower, and "slept long enough" would then be
        // a flaky assertion about the scheduler instead of about behaviour.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (fixture.triggers().first?.renderCount ?? 0) < 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(fixture.service.brightnessMode(for: displayA), .softwareLift,
                       "no headroom means no upgrade to the real thing")
        XCTAssertEqual(
            try XCTUnwrap(fixture.service.engagedBrightness(for: displayA)),
            EDROverlayService.softwareBoostCap,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(fixture.io.written[displayA].flatMap(\.red.last))),
            EDROverlayService.softwareBoostCap,
            accuracy: 0.001,
            "repeated polls must not drift the applied value"
        )
        XCTAssertGreaterThanOrEqual(fixture.triggers().first?.renderCount ?? 0, 3,
                                    "the trigger keeps presenting frames while the watch runs")

        fixture.service.removeAllOverlays()
    }

    /// Going back to neutral while the watch is polling must stop it, and it
    /// must not write gamma afterwards — the user asked for nothing.
    func testTheWatchStopsWhenTheUserReturnsToNeutral() throws {
        let fixture = makeService(headroom: 1.0)
        try fixture.service.applyExtendedBrightness(1.5, displayID: displayA)

        fixture.service.removeOverlay(for: displayA)
        fixture.io.forgetWrites()

        // Two poll intervals is enough for a still-running watch to have written.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertNil(fixture.service.currentHeadroom(for: displayA))
        XCTAssertNil(fixture.service.brightnessMode(for: displayA))
        XCTAssertTrue(fixture.io.written.isEmpty, "a stopped watch must not keep writing the gamma table")
    }

    // MARK: - Error paths

    func testApplyThrowsWhenMultiplierBelowMinimum() {
        let fixture = makeService(headroom: 1.6)
        XCTAssertThrowsError(try fixture.service.applyExtendedBrightness(0.99, displayID: displayA)) { error in
            guard case TuneError.usage = error else {
                return XCTFail("expected TuneError.usage, got \(error)")
            }
        }
    }

    func testApplyThrowsWhenMultiplierAboveMaximum() {
        let fixture = makeService(headroom: 1.6)
        XCTAssertThrowsError(try fixture.service.applyExtendedBrightness(1.61, displayID: displayA)) { error in
            guard case TuneError.usage = error else {
                return XCTFail("expected TuneError.usage, got \(error)")
            }
        }
    }

    func testApplyThrowsWhenTheTriggerCannotBeCreated() {
        let io = FakeGammaIO()
        let service = EDROverlayService(
            gamma: DisplayGammaController(io: io),
            headroomProvider: { _ in 1.6 },
            triggerFactory: { _ in nil }
        )
        XCTAssertThrowsError(try service.applyExtendedBrightness(1.5, displayID: displayA)) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected TuneError.failed, got \(error)")
            }
        }
    }

    func testApplyWithoutDisplayIDTargetsTheBuiltInDisplayOrFailsCleanly() {
        // No display session is guaranteed in unit tests (CI is headless, a dev
        // Mac is not). Either outcome is fine; a crash is not.
        let fixture = makeService(headroom: 1.6)
        do {
            try fixture.service.applyExtendedBrightness(1.5)
            XCTAssertEqual(fixture.triggers().count, 1, "a display session must yield exactly one trigger")
            fixture.service.removeAllOverlays()
        } catch {
            guard case TuneError.unsupported = error else {
                return XCTFail("expected TuneError.unsupported without a built-in display, got \(error)")
            }
        }
    }

    // MARK: - Removal / neutral

    func testNeutralMultiplierRemovesTriggerAndRestoresGamma() throws {
        let fixture = makeService(headroom: 1.6)
        try fixture.service.applyExtendedBrightness(1.4, displayID: displayA)
        let trigger = try XCTUnwrap(fixture.triggers().first)

        try fixture.service.applyExtendedBrightness(SafetyPolicy.extendedBrightnessMin, displayID: displayA)

        XCTAssertNil(fixture.service.currentHeadroom(for: displayA))
        XCTAssertNil(fixture.service.engagedBrightness(for: displayA))
        XCTAssertTrue(trigger.removed, "neutral must leave nothing on screen")
        XCTAssertEqual(fixture.io.restoreCount, 1, "and hand the gamma table back to the system")
        XCTAssertTrue(fixture.io.written.isEmpty)

        // Reapplying after neutral has to work — the old code left the target
        // half-removed and the second boost never took.
        try fixture.service.applyExtendedBrightness(1.2, displayID: displayA)
        XCTAssertEqual(fixture.triggers().count, 2)
        XCTAssertEqual(try XCTUnwrap(fixture.io.written[displayA].flatMap(\.red.last)), 1.2, accuracy: 0.001)
    }

    func testRemoveAllOverlaysClearsEveryDisplay() throws {
        let fixture = makeService(
            headroom: 1.6,
            headroomByDisplay: [displayA: 1.6, displayB: 1.6]
        )
        try fixture.service.applyExtendedBrightness(1.4, displayID: displayA)
        try fixture.service.applyExtendedBrightness(1.2, displayID: displayB)
        XCTAssertEqual(fixture.triggers().count, 2)

        fixture.service.removeAllOverlays()

        XCTAssertNil(fixture.service.currentHeadroom(for: displayA))
        XCTAssertNil(fixture.service.currentHeadroom(for: displayB))
        XCTAssertTrue(fixture.triggers().allSatisfy { $0.removed })
        XCTAssertTrue(fixture.io.written.isEmpty)
    }

    func testCurrentHeadroomIsNilWithoutOverlay() {
        let fixture = makeService(headroom: 1.6)
        XCTAssertNil(fixture.service.currentHeadroom(for: displayA))
    }

    // MARK: - Reassert

    func testReassertRewritesTheBoostAfterTheSystemDroppedIt() throws {
        let fixture = makeService(headroom: 1.6)
        try fixture.service.applyExtendedBrightness(1.35, displayID: displayA)

        // Simulate macOS resetting the gamma table (sleep/wake, display change).
        fixture.io.restoreSystemRamps()
        XCTAssertNil(fixture.io.written[displayA])

        fixture.service.reassert()

        XCTAssertEqual(try XCTUnwrap(fixture.io.written[displayA].flatMap(\.red.last)), 1.35, accuracy: 0.001)
    }

    // MARK: - Trigger configuration

    func testTriggerLayerIsConfiguredForExtendedRangeContent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device in this environment")
        }
        let layer = CAMetalLayer()

        EDRTriggerWindow.configureMetalLayer(layer, device: device)

        // All three together are what makes the system treat this as EDR
        // content; missing any one silently downgrades it to SDR.
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.extendedLinearSRGB)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 1, height: 1),
                       "one pixel is enough to request headroom")
    }

    func testSystemEDRHeadroomIsNilForUnknownDisplay() {
        let service = EDROverlayService()
        XCTAssertNil(service.systemEDRHeadroom(for: displayA))
    }
}

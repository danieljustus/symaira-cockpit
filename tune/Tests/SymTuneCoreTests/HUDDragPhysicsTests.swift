import XCTest
@testable import SymTuneCore

/// How the HUD comes off the edge it is parked against.
///
/// This is the one part of the HUD that cannot be judged from a screenshot: it
/// is a feel, and a feel is made of arithmetic. The properties below are the
/// ones that decide whether the gesture reads as peeling something off a
/// surface or as a window with a lazy drag handle — so they are asserted rather
/// than eyeballed.
final class HUDDragPhysicsTests: XCTestCase {

    private func translation(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }

    // MARK: - The rubber band

    func testRubberBandStartsAtZeroAndRisesMonotonically() {
        XCTAssertEqual(HUDDragPhysics.rubberBand(0), 0)

        var previous: CGFloat = 0
        for distance in stride(from: CGFloat(1), through: 400, by: 7) {
            let value = HUDDragPhysics.rubberBand(distance)
            XCTAssertGreaterThan(value, previous, "band went backwards at \(distance)")
            previous = value
        }
    }

    /// The whole reason for a band rather than a constant fraction: it resists
    /// harder the further it is pulled, and it never lets go entirely.
    ///
    /// The asymptote is the limit itself, so an attached HUD can never be more
    /// than ``HUDDragPhysics/detachDistance`` from its dock however hard it is
    /// pulled — and in practice never gets close, because it detaches first.
    func testRubberBandIsBoundedNoMatterHowHardItIsPulled() {
        XCTAssertLessThan(HUDDragPhysics.rubberBand(10_000), HUDDragPhysics.detachDistance)
        XCTAssertLessThan(
            HUDDragPhysics.rubberBand(HUDDragPhysics.detachDistance),
            HUDDragPhysics.detachDistance / 2,
            "the band barely resisted at the point it lets go"
        )
    }

    func testRubberBandAlwaysLagsThePointer() {
        for distance in stride(from: CGFloat(1), through: 200, by: 3) {
            XCTAssertLessThan(
                HUDDragPhysics.rubberBand(distance),
                distance,
                "the HUD outran the pointer at \(distance)"
            )
        }
    }

    // MARK: - Attached

    func testAtRestTheHUDHasNotMovedAndIsNotStretched() {
        let state = HUDDragPhysics.resolve(translation: .zero, dock: .notch)
        XCTAssertEqual(state.offset, .zero)
        XCTAssertEqual(state.stretch, CGSize(width: 1, height: 1))
        XCTAssertFalse(state.isDetached)
        // The gesture exists even at zero translation; the view needs to know
        // that so it tracks rather than springs.
        XCTAssertTrue(state.isActive)
    }

    func testASmallPullMovesTheHUDLessThanThePointer() {
        let state = HUDDragPhysics.resolve(translation: translation(0, 20), dock: .notch)
        XCTAssertFalse(state.isDetached)
        XCTAssertGreaterThan(state.offset.height, 0)
        XCTAssertLessThan(state.offset.height, 20)
    }

    /// Pulling a notch HUD straight down elongates it and necks it, which is
    /// what "it stretches before it comes off" means in numbers.
    func testPullingTheNotchDownStretchesItVerticallyAndNecksIt() {
        let state = HUDDragPhysics.resolve(
            translation: translation(0, HUDDragPhysics.detachDistance - 1),
            dock: .notch
        )
        XCTAssertGreaterThan(state.stretch.height, 1)
        XCTAssertLessThan(state.stretch.width, 1)
    }

    /// Sliding it *along* the bezel is not peeling it off, so it barely
    /// deforms — the pull has almost no component away from the anchor.
    func testSlidingTheNotchSidewaysBarelyStretchesIt() {
        let state = HUDDragPhysics.resolve(
            translation: translation(HUDDragPhysics.detachDistance - 1, 0),
            dock: .notch
        )
        XCTAssertEqual(state.stretch.height, 1, accuracy: 0.001)
        XCTAssertEqual(state.stretch.width, 1, accuracy: 0.001)
    }

    /// An edge dock is anchored on a side, so the axes swap: pulling it inward
    /// is what stretches it.
    func testPullingAnEdgeDockInwardStretchesItHorizontally() {
        let state = HUDDragPhysics.resolve(
            translation: translation(-(HUDDragPhysics.detachDistance - 1), 0),
            dock: .right(.center)
        )
        XCTAssertGreaterThan(state.stretch.width, 1)
        XCTAssertLessThan(state.stretch.height, 1)
    }

    func testStretchNeverExceedsTheDeclaredMaximum() {
        for distance in stride(from: CGFloat(0), through: HUDDragPhysics.detachDistance, by: 0.5) {
            let state = HUDDragPhysics.resolve(translation: translation(0, distance), dock: .notch)
            XCTAssertLessThanOrEqual(
                state.stretch.height,
                1 + HUDDragPhysics.maxStretch + 0.0001
            )
            XCTAssertGreaterThan(state.stretch.width, 0, "the HUD collapsed to nothing")
        }
    }

    // MARK: - Detaching

    func testItDetachesOnceThePointerPassesTheThreshold() {
        let attached = HUDDragPhysics.resolve(
            translation: translation(0, HUDDragPhysics.detachDistance - 0.5),
            dock: .notch
        )
        let detached = HUDDragPhysics.resolve(
            translation: translation(0, HUDDragPhysics.detachDistance + 0.5),
            dock: .notch
        )
        XCTAssertFalse(attached.isDetached)
        XCTAssertTrue(detached.isDetached)
    }

    /// The property the whole design hangs on: at the moment it lets go, the
    /// HUD must not jump. Both branches have to agree at the threshold, or the
    /// shape teleports forward by everything the resistance had swallowed.
    func testTheHUDDoesNotJumpAtTheMomentItLetsGo() {
        let epsilon: CGFloat = 0.0001
        let before = HUDDragPhysics.resolve(
            translation: translation(0, HUDDragPhysics.detachDistance - epsilon),
            dock: .notch
        )
        let after = HUDDragPhysics.resolve(
            translation: translation(0, HUDDragPhysics.detachDistance + epsilon),
            dock: .notch
        )
        XCTAssertEqual(before.offset.height, after.offset.height, accuracy: 0.01)
    }

    func testOnceDetachedItTracksThePointerOneToOne() {
        let near = HUDDragPhysics.resolve(translation: translation(0, 200), dock: .notch)
        let far = HUDDragPhysics.resolve(translation: translation(0, 300), dock: .notch)
        XCTAssertEqual(far.offset.height - near.offset.height, 100, accuracy: 0.001)
    }

    /// Free of the bezel there is nothing left to stretch against, so the
    /// tension is gone and the view's spring takes the shape back to square.
    func testADetachedHUDCarriesNoTension() {
        let state = HUDDragPhysics.resolve(translation: translation(120, 90), dock: .notch)
        XCTAssertTrue(state.isDetached)
        XCTAssertEqual(state.stretch, CGSize(width: 1, height: 1))
    }

    /// Whatever direction it is pulled, the HUD ends up on the line between
    /// the dock and the pointer — never off to one side of it.
    func testTheHUDMovesAlongThePullNoMatterTheDirection() {
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: 0.3) {
            for distance in [CGFloat(12), 37, 39, 240] {
                let pull = translation(distance * CGFloat(cos(angle)), distance * CGFloat(sin(angle)))
                let state = HUDDragPhysics.resolve(translation: pull, dock: .notch)
                // Cross product of pull and offset is zero when they are
                // parallel, and both point the same way.
                let cross = pull.width * state.offset.height - pull.height * state.offset.width
                XCTAssertEqual(cross, 0, accuracy: 0.01, "offset left the pull's axis")
                let dot = pull.width * state.offset.width + pull.height * state.offset.height
                XCTAssertGreaterThan(dot, 0, "the HUD moved against the pull")
            }
        }
    }

    // MARK: - Which way each dock stretches

    func testOnlyTheNotchIsAnchoredAlongItsHorizontalEdge() {
        XCTAssertTrue(HUDDock.notch.stretchesVertically)
        for dock in HUDDock.edgeCases {
            XCTAssertFalse(dock.stretchesVertically, "\(dock.storageKey) stretched the wrong way")
        }
    }
}

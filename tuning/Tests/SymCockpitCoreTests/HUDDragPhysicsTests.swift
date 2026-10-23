import XCTest
@testable import SymCockpitCore

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

    private func dot(_ lhs: CGSize, _ rhs: CGSize) -> CGFloat {
        lhs.width * rhs.width + lhs.height * rhs.height
    }

    private func length(_ size: CGSize) -> CGFloat {
        hypot(size.width, size.height)
    }

    /// The pull a test applies for a given direction, as an angle, at a
    /// distance.
    private func pull(angle: Double, distance: CGFloat) -> CGSize {
        translation(distance * CGFloat(cos(angle)), distance * CGFloat(sin(angle)))
    }

    private var angles: [Double] { Array(stride(from: 0.0, to: 2 * Double.pi, by: 0.3)) }

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

    /// Sliding along the bezel is the one way an attached HUD actually moves,
    /// and it does so with resistance: less than the pointer, but not nothing.
    func testASmallSlideAlongTheBezelMovesTheHUDLessThanThePointer() {
        let state = HUDDragPhysics.resolve(translation: translation(20, 0), dock: .notch)
        XCTAssertFalse(state.isDetached)
        XCTAssertGreaterThan(state.offset.width, 0)
        XCTAssertLessThan(state.offset.width, 20)
        XCTAssertEqual(state.offset.height, 0, accuracy: 1e-9)
    }

    /// The headline property of the edge-anchored drag: pulling the notch down
    /// does not move its top edge at all. The edge stays on the bezel and the
    /// *stretch* is what carries the pull.
    func testPullingTheNotchDownKeepsItsTopEdgePinnedAndStretchesTheBody() {
        for distance in stride(from: CGFloat(1), to: HUDDragPhysics.detachDistance, by: 1.5) {
            let state = HUDDragPhysics.resolve(translation: translation(0, distance), dock: .notch)
            XCTAssertEqual(state.offset, .zero, "the notch's top edge left the bezel at \(distance)")
            XCTAssertGreaterThan(state.stretch.height, 1, "nothing stretched at \(distance)")
        }
    }

    /// Pinned means pinned in every direction and on every dock: whatever the
    /// angle of an attached pull, the anchored edge has no displacement along
    /// the axis that leads away from it.
    func testAnAttachedAnchorNeverMovesAlongThePullAxisOnAnyDock() {
        for dock in HUDDock.allCases {
            for angle in angles {
                for distance in [CGFloat(2), 10, 25, HUDDragPhysics.detachDistance - 0.01] {
                    let state = HUDDragPhysics.resolve(translation: pull(angle: angle, distance: distance), dock: dock)
                    XCTAssertFalse(state.isDetached)
                    XCTAssertEqual(
                        dot(state.offset, dock.awayDirection),
                        0,
                        accuracy: 1e-9,
                        "\(dock.storageKey) left its edge at \(distance) pt, angle \(angle)"
                    )
                }
            }
        }
    }

    /// Pulling *into* the bezel peels nothing: there is no surface to stretch
    /// away from, and the edge cannot go through it.
    func testPushingTheNotchIntoTheBezelDoesNotStretchIt() {
        let state = HUDDragPhysics.resolve(translation: translation(0, -20), dock: .notch)
        XCTAssertEqual(state.stretch, CGSize(width: 1, height: 1))
        XCTAssertEqual(state.offset, .zero)
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

    /// The stretch builds up as the pull does — it never relaxes on the way to
    /// the threshold.
    func testTheStretchGrowsMonotonicallyWhileAttached() {
        var previous: CGFloat = 1
        for distance in stride(from: CGFloat(0.5), through: HUDDragPhysics.detachDistance, by: 0.5) {
            let state = HUDDragPhysics.resolve(translation: translation(0, distance), dock: .notch)
            XCTAssertGreaterThanOrEqual(state.stretch.height, previous, "stretch shrank at \(distance)")
            previous = state.stretch.height
        }
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
        XCTAssertEqual(state.offset.width, 0, accuracy: 1e-9, "the edge dock's anchored side left the screen edge")
    }

    func testPullingTheLeftEdgeDockInwardStretchesItToo() {
        let state = HUDDragPhysics.resolve(
            translation: translation(HUDDragPhysics.detachDistance - 1, 0),
            dock: .left(.top)
        )
        XCTAssertGreaterThan(state.stretch.width, 1)
        XCTAssertEqual(state.offset, .zero)
    }

    /// An edge dock slides along its edge with resistance, like the notch
    /// along the bezel, while staying attached.
    func testAnEdgeDockSlidesAlongItsEdgeWithResistance() {
        let state = HUDDragPhysics.resolve(translation: translation(0, 20), dock: .right(.center))
        XCTAssertGreaterThan(state.offset.height, 0)
        XCTAssertLessThan(state.offset.height, 20)
        XCTAssertEqual(state.offset.width, 0, accuracy: 1e-9)
    }

    func testStretchNeverExceedsTheDeclaredMaximum() {
        for distance in stride(from: CGFloat(0), through: 400, by: 0.5) {
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
    /// HUD must not jump — neither where it is nor what shape it is. The
    /// attached and free formulas are blended rather than switched, so both
    /// sides of the threshold agree.
    func testNeitherPositionNorShapeJumpsAtTheMomentItLetsGo() {
        let epsilon: CGFloat = 0.0001
        for dock in HUDDock.allCases {
            for angle in angles {
                let before = HUDDragPhysics.resolve(
                    translation: pull(angle: angle, distance: HUDDragPhysics.detachDistance - epsilon),
                    dock: dock
                )
                let after = HUDDragPhysics.resolve(
                    translation: pull(angle: angle, distance: HUDDragPhysics.detachDistance + epsilon),
                    dock: dock
                )
                XCTAssertEqual(before.offset.width, after.offset.width, accuracy: 0.01, "\(dock.storageKey) \(angle)")
                XCTAssertEqual(before.offset.height, after.offset.height, accuracy: 0.01, "\(dock.storageKey) \(angle)")
                XCTAssertEqual(before.stretch.width, after.stretch.width, accuracy: 0.001, "\(dock.storageKey) \(angle)")
                XCTAssertEqual(before.stretch.height, after.stretch.height, accuracy: 0.001, "\(dock.storageKey) \(angle)")
            }
        }
    }

    /// Continuity at one point is not continuity. Walk the whole pull in small
    /// steps and bound how far offset and stretch may move between neighbours:
    /// a hidden jump anywhere — at the threshold or where the blend ends —
    /// breaks the bound by an order of magnitude.
    func testOffsetAndStretchAreContinuousAlongTheWholePull() {
        let step: CGFloat = 0.25
        for dock in HUDDock.allCases {
            for angle in angles {
                var previous = HUDDragPhysics.resolve(translation: pull(angle: angle, distance: step), dock: dock)
                for distance in stride(from: 2 * step, through: 200, by: step) {
                    let state = HUDDragPhysics.resolve(translation: pull(angle: angle, distance: distance), dock: dock)
                    XCTAssertLessThan(
                        length(CGSize(
                            width: state.offset.width - previous.offset.width,
                            height: state.offset.height - previous.offset.height
                        )),
                        4 * step,
                        "\(dock.storageKey) offset jumped at \(distance), angle \(angle)"
                    )
                    XCTAssertLessThan(
                        abs(state.stretch.height - previous.stretch.height) + abs(state.stretch.width - previous.stretch.width),
                        0.1 * step,
                        "\(dock.storageKey) stretch jumped at \(distance), angle \(angle)"
                    )
                    previous = state
                }
            }
        }
    }

    /// Past the threshold the stretch is taken out gradually: the shape keeps
    /// its tension at the moment it lets go and relaxes to square only after
    /// ``HUDDragPhysics/blendDistance`` more points of pull.
    func testTheStretchRelaxesOverTheBlendDistanceInsteadOfSnappingOut() {
        let detach = HUDDragPhysics.detachDistance
        let blend = HUDDragPhysics.blendDistance

        let atThreshold = HUDDragPhysics.resolve(translation: translation(0, detach + 0.001), dock: .notch)
        XCTAssertEqual(atThreshold.stretch.height, 1 + HUDDragPhysics.maxStretch, accuracy: 0.001)

        var previous = atThreshold.stretch.height
        for distance in stride(from: detach + 1, through: detach + blend, by: 1) {
            let stretch = HUDDragPhysics.resolve(translation: translation(0, distance), dock: .notch).stretch.height
            XCTAssertLessThanOrEqual(stretch, previous, "the stretch grew again at \(distance)")
            previous = stretch
        }

        let relaxed = HUDDragPhysics.resolve(translation: translation(0, detach + blend), dock: .notch)
        XCTAssertEqual(relaxed.stretch, CGSize(width: 1, height: 1))
    }

    func testTheDetachBlendIsZeroUntilTheThresholdAndOneAfterTheBlendDistance() {
        let detach = HUDDragPhysics.detachDistance
        XCTAssertEqual(HUDDragPhysics.detachBlend(0), 0)
        XCTAssertEqual(HUDDragPhysics.detachBlend(detach), 0)
        XCTAssertEqual(HUDDragPhysics.detachBlend(detach + HUDDragPhysics.blendDistance), 1, accuracy: 1e-9)
        XCTAssertEqual(HUDDragPhysics.detachBlend(detach + 10 * HUDDragPhysics.blendDistance), 1)

        var previous: CGFloat = 0
        for distance in stride(from: detach, through: detach + HUDDragPhysics.blendDistance, by: 0.5) {
            let value = HUDDragPhysics.detachBlend(distance)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        // A smoothstep leaves the threshold with no slope, so the HUD does not
        // change speed the instant it lets go.
        XCTAssertLessThan(HUDDragPhysics.detachBlend(detach + 0.1), 0.0001)
    }

    func testOnceDetachedItTracksThePointerOneToOne() {
        let near = HUDDragPhysics.resolve(translation: translation(0, 200), dock: .notch)
        let far = HUDDragPhysics.resolve(translation: translation(0, 300), dock: .notch)
        XCTAssertEqual(far.offset.height - near.offset.height, 100, accuracy: 0.001)
    }

    /// Settled, the HUD sits a fixed ``HUDDragPhysics/detachLag`` behind the
    /// pointer, wherever the pointer is.
    func testASettledHUDKeepsAConstantLagBehindThePointer() {
        for distance in [CGFloat(80), 120, 400] {
            let state = HUDDragPhysics.resolve(translation: translation(0, distance), dock: .notch)
            XCTAssertEqual(distance - state.offset.height, HUDDragPhysics.detachLag, accuracy: 0.001)
        }
    }

    /// Free of the bezel there is nothing left to stretch against, so the
    /// tension is gone and the shape is square again.
    func testASettledDetachedHUDCarriesNoTension() {
        let state = HUDDragPhysics.resolve(translation: translation(120, 90), dock: .notch)
        XCTAssertTrue(state.isDetached)
        XCTAssertEqual(state.stretch, CGSize(width: 1, height: 1))
    }

    /// Detached and settled, the HUD ends up on the line between the dock and
    /// the pointer — never off to one side of it.
    func testASettledHUDMovesAlongThePullNoMatterTheDirection() {
        let settled = HUDDragPhysics.detachDistance + HUDDragPhysics.blendDistance
        for angle in angles {
            for distance in [settled + 0.5, settled + 40, 240] {
                let pull = pull(angle: angle, distance: distance)
                let state = HUDDragPhysics.resolve(translation: pull, dock: .notch)
                // Cross product of pull and offset is zero when they are
                // parallel, and both point the same way.
                let cross = pull.width * state.offset.height - pull.height * state.offset.width
                XCTAssertEqual(cross, 0, accuracy: 0.01, "offset left the pull's axis")
                XCTAssertGreaterThan(dot(pull, state.offset), 0, "the HUD moved against the pull")
            }
        }
    }

    /// Whatever the direction and wherever in the pull, the HUD never travels
    /// *against* the pointer.
    func testTheHUDNeverMovesAgainstThePull() {
        for angle in angles {
            for distance in [CGFloat(12), 37, 39, 50, 240] {
                let pull = pull(angle: angle, distance: distance)
                let state = HUDDragPhysics.resolve(translation: pull, dock: .notch)
                XCTAssertGreaterThanOrEqual(dot(pull, state.offset), -1e-9, "the HUD moved against the pull")
            }
        }
    }

    // MARK: - Reduce Motion

    /// With Reduce Motion nothing deforms, at any distance, in any direction,
    /// on any dock, attached or detached.
    func testReduceMotionNeverStretchesAnything() {
        for dock in HUDDock.allCases {
            for angle in angles {
                for distance in [CGFloat(1), 20, 37, 39, 60, 300] {
                    let state = HUDDragPhysics.resolve(
                        translation: pull(angle: angle, distance: distance),
                        dock: dock,
                        reduceMotion: true
                    )
                    XCTAssertEqual(state.stretch, CGSize(width: 1, height: 1), "\(dock.storageKey) stretched at \(distance)")
                    XCTAssertTrue(state.isActive)
                }
            }
        }
    }

    /// What is left is plain translation: the HUD still follows the pointer
    /// with the same resistance, still lets go at the same distance, and still
    /// moves along the pull, with no deformation to show the pull.
    func testReduceMotionStillFollowsThePointerWithResistance() {
        let attached = HUDDragPhysics.resolve(translation: translation(0, 20), dock: .notch, reduceMotion: true)
        XCTAssertFalse(attached.isDetached)
        XCTAssertEqual(attached.offset.height, HUDDragPhysics.rubberBand(20), accuracy: 1e-9)
        XCTAssertEqual(attached.offset.width, 0, accuracy: 1e-9)

        let detached = HUDDragPhysics.resolve(translation: translation(0, 300), dock: .notch, reduceMotion: true)
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(detached.offset.height, 300 - HUDDragPhysics.detachLag, accuracy: 0.001)
    }

    func testReduceMotionIsAlsoContinuousAtTheThreshold() {
        let epsilon: CGFloat = 0.0001
        for angle in angles {
            let before = HUDDragPhysics.resolve(
                translation: pull(angle: angle, distance: HUDDragPhysics.detachDistance - epsilon),
                dock: .notch,
                reduceMotion: true
            )
            let after = HUDDragPhysics.resolve(
                translation: pull(angle: angle, distance: HUDDragPhysics.detachDistance + epsilon),
                dock: .notch,
                reduceMotion: true
            )
            XCTAssertEqual(before.offset.width, after.offset.width, accuracy: 0.01)
            XCTAssertEqual(before.offset.height, after.offset.height, accuracy: 0.01)
        }
    }

    // MARK: - Which way each dock stretches

    func testOnlyTheNotchIsAnchoredAlongItsHorizontalEdge() {
        XCTAssertTrue(HUDDock.notch.stretchesVertically)
        for dock in HUDDock.edgeCases {
            XCTAssertFalse(dock.stretchesVertically, "\(dock.storageKey) stretched the wrong way")
        }
    }

    func testEachDockPointsAwayFromItsAnchoredEdge() {
        XCTAssertEqual(HUDDock.notch.awayDirection, CGSize(width: 0, height: 1))
        XCTAssertEqual(HUDDock.left(.center).awayDirection, CGSize(width: 1, height: 0))
        XCTAssertEqual(HUDDock.right(.center).awayDirection, CGSize(width: -1, height: 0))
        for dock in HUDDock.allCases {
            XCTAssertEqual(length(dock.awayDirection), 1, accuracy: 1e-9)
        }
    }
}

/// What lifting the pointer off the HUD means.
///
/// The velocity at the moment of release is the one input the drag itself never
/// sees, and it is what separates a flick from a hesitation. Pure arithmetic as
/// well, so — like the drag — asserted rather than felt.
final class HUDDragReleaseTests: XCTestCase {

    private func translation(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }

    private func length(_ size: CGSize) -> CGFloat {
        hypot(size.width, size.height)
    }

    /// A pull that stops short and is let go gently settles back; one that
    /// was pulled well past the threshold stays detached.
    func testAGentleReleaseBelowTheThresholdSnapsBack() {
        let release = HUDDragPhysics.release(
            translation: translation(0, 20),
            velocity: translation(0, 30),
            dock: .notch
        )
        XCTAssertEqual(release.outcome, .snapBack)
    }

    func testASlowReleasePastTheThresholdDetaches() {
        let release = HUDDragPhysics.release(translation: translation(0, 80), velocity: .zero, dock: .notch)
        XCTAssertEqual(release.outcome, .detach)
        XCTAssertEqual(release.momentum, .zero)
        XCTAssertEqual(release.projectedTranslation, translation(0, 80))
    }

    /// The velocity is what separates a flick from a hesitation: the same
    /// shallow pull detaches when the pointer is leaving fast and snaps back
    /// when it is not.
    func testAFastFlickAwayDetachesWhereASlowReleaseOfTheSamePullDoesNot() {
        let pulled = translation(0, 20)
        let slow = HUDDragPhysics.release(translation: pulled, velocity: translation(0, 40), dock: .notch)
        let flick = HUDDragPhysics.release(translation: pulled, velocity: translation(0, 1_800), dock: .notch)
        XCTAssertEqual(slow.outcome, .snapBack)
        XCTAssertEqual(flick.outcome, .detach)
        XCTAssertGreaterThan(flick.projectedTranslation.height, slow.projectedTranslation.height)
    }

    /// A pull that went past the threshold and is then flicked back towards the
    /// dock was a change of mind, not a drop.
    func testAFlickBackTowardsTheDockCancelsAPullThatHadDetached() {
        let release = HUDDragPhysics.release(
            translation: translation(0, 60),
            velocity: translation(0, -700),
            dock: .notch
        )
        XCTAssertEqual(release.outcome, .snapBack)
    }

    func testMomentumIsBoundedAndProjectionAddsIt() {
        let release = HUDDragPhysics.release(
            translation: translation(10, 10),
            velocity: translation(30_000, 0),
            dock: .notch
        )
        XCTAssertEqual(length(release.momentum), HUDDragPhysics.maxMomentum, accuracy: 1e-6)
        XCTAssertEqual(release.projectedTranslation.width, 10 + release.momentum.width, accuracy: 1e-9)
        XCTAssertEqual(release.projectedTranslation.height, 10 + release.momentum.height, accuracy: 1e-9)
    }

    /// Lateral pull, so the attached HUD actually has an offset for the spring
    /// to carry. A flick away starts the spring moving away from home — a
    /// *negative* relative velocity — a slow release barely does, and a pointer
    /// already heading home starts it positive.
    func testTheSpringStartsAtThePointersPaceRelativeToTheWayHome() {
        let pulled = translation(30, 0)
        let flickAway = HUDDragPhysics.release(translation: pulled, velocity: translation(1_500, 0), dock: .notch).spring
        let slowAway = HUDDragPhysics.release(translation: pulled, velocity: translation(60, 0), dock: .notch).spring
        let flickHome = HUDDragPhysics.release(translation: pulled, velocity: translation(-1_500, 0), dock: .notch).spring

        XCTAssertLessThan(flickAway.initialVelocity, slowAway.initialVelocity)
        XCTAssertLessThan(slowAway.initialVelocity, 0)
        XCTAssertGreaterThan(flickHome.initialVelocity, 0)
        XCTAssertGreaterThan(abs(flickAway.initialVelocity), abs(slowAway.initialVelocity))

        for spring in [flickAway, slowAway, flickHome] {
            XCTAssertLessThanOrEqual(abs(spring.initialVelocity), HUDDragPhysics.maxInitialVelocity)
        }
    }

    func testAFastReleaseGetsAQuickerBouncierSpringThanASlowOne() {
        let pulled = translation(0, 20)
        let soft = HUDDragPhysics.release(translation: pulled, velocity: .zero, dock: .notch).spring
        let flick = HUDDragPhysics.release(translation: pulled, velocity: translation(0, 2_000), dock: .notch).spring

        XCTAssertLessThan(flick.dampingFraction, soft.dampingFraction)
        XCTAssertLessThan(flick.response, soft.response)
        for spring in [soft, flick] {
            XCTAssertGreaterThan(spring.dampingFraction, 0)
            XCTAssertLessThanOrEqual(spring.dampingFraction, 1)
            XCTAssertGreaterThan(spring.response, 0)
        }
    }

    func testTheSpringBecomesBouncierAndQuickerAsTheReleaseGetsFaster() {
        var previous = HUDDragPhysics.release(translation: translation(0, 20), velocity: .zero, dock: .notch).spring
        for speed in stride(from: CGFloat(100), through: 2_500, by: 100) {
            let spring = HUDDragPhysics.release(translation: translation(0, 20), velocity: translation(0, speed), dock: .notch).spring
            XCTAssertLessThanOrEqual(spring.dampingFraction, previous.dampingFraction, "damping rose at \(speed)")
            XCTAssertLessThanOrEqual(spring.response, previous.response, "response rose at \(speed)")
            previous = spring
        }
    }

    func testReleasingWithoutMomentumUsesTheSoftSpring() {
        let release = HUDDragPhysics.release(translation: translation(25, 0), velocity: .zero, dock: .notch)
        XCTAssertEqual(release.spring, .soft)
    }

    /// Nothing has moved while a vertical pull on the notch is attached — the
    /// stretch carries it — so there is no offset for a velocity to be relative
    /// to, and the spring does not make one up.
    func testAPinnedHUDHasNoOffsetVelocityToCarry() {
        let release = HUDDragPhysics.release(translation: translation(0, 20), velocity: translation(0, 2_000), dock: .notch)
        XCTAssertEqual(release.spring.initialVelocity, 0)
    }

    func testReduceMotionStillDecidesTheOutcomeButNeverAddsVelocity() {
        let flick = HUDDragPhysics.release(
            translation: translation(30, 0),
            velocity: translation(1_500, 0),
            dock: .notch,
            reduceMotion: true
        )
        XCTAssertEqual(flick.outcome, .detach)
        XCTAssertEqual(flick.spring.initialVelocity, 0)
    }

    func testReleaseWorksTheSameWayOnEdgeDocks() {
        let flick = HUDDragPhysics.release(
            translation: translation(-20, 0),
            velocity: translation(-1_800, 0),
            dock: .right(.center)
        )
        XCTAssertEqual(flick.outcome, .detach)
        let slow = HUDDragPhysics.release(
            translation: translation(-20, 0),
            velocity: translation(-30, 0),
            dock: .right(.center)
        )
        XCTAssertEqual(slow.outcome, .snapBack)
    }
}

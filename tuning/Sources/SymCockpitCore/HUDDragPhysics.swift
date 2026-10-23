import CoreGraphics
import Foundation

/// What a drag is currently doing to the HUD's shape and position.
///
/// Returned by ``HUDDragPhysics/resolve(translation:dock:reduceMotion:)`` and
/// applied by the view as a scale about the anchored edge followed by an offset.
/// Keeping it a value type with no AppKit in it is what lets the interesting
/// half of the gesture — the part where the HUD is resisting — be checked in
/// tests rather than by eye.
public struct HUDDragState: Equatable, Sendable {
    /// Where the HUD's **anchored edge** has moved to, which is not the
    /// pointer's translation.
    ///
    /// While the HUD is attached this is zero along the pull axis — the edge
    /// stays on the bezel and only the body stretches away from it (see
    /// ``stretch``); at most it slides *along* the bezel. Once the HUD has let go
    /// it carries the whole shape after the pointer.
    public var offset: CGSize
    /// Scale factors applied about the anchored edge, so the edge itself holds
    /// still while the far end moves. `1×1` at rest.
    public var stretch: CGSize
    /// Whether the HUD has come off the edge and now follows the pointer
    /// one-to-one.
    public var isDetached: Bool
    /// Whether a drag is in progress at all. The view reads this to choose
    /// between following the pointer and springing home.
    public var isActive: Bool

    public init(
        offset: CGSize = .zero,
        stretch: CGSize = CGSize(width: 1, height: 1),
        isDetached: Bool = false,
        isActive: Bool = false
    ) {
        self.offset = offset
        self.stretch = stretch
        self.isDetached = isDetached
        self.isActive = isActive
    }

    /// The HUD sitting in its dock, untouched.
    public static let resting = HUDDragState()
}

/// The spring a released HUD settles on.
///
/// Derived from the pointer's speed at the moment of release (see
/// ``HUDDragPhysics/release(translation:velocity:dock:reduceMotion:)``) so that
/// a slow hand-off settles softly and a flick keeps its momentum. It is plain
/// numbers rather than a SwiftUI `Animation` for the same reason the rest of
/// this file is: the view should only translate it, and the mapping from speed
/// to feel stays testable.
public struct HUDReleaseSpring: Equatable, Sendable {
    /// Seconds for one natural period of the spring — shorter is snappier.
    public var response: Double
    /// `1` settles without overshoot; below it the shape rings past rest.
    public var dampingFraction: Double
    /// How fast the shape is already travelling when the spring takes over, as
    /// a multiple of the distance still to cover per second.
    ///
    /// Positive means *towards* the dock (the pointer was already heading home),
    /// negative means away from it — a flick that carries the shape further
    /// out before the spring wins it back. Zero when nothing translates.
    public var initialVelocity: Double

    public init(response: Double, dampingFraction: Double, initialVelocity: Double = 0) {
        self.response = response
        self.dampingFraction = dampingFraction
        self.initialVelocity = initialVelocity
    }

    /// The unhurried settle used when the HUD is let go without any momentum.
    public static let soft = HUDReleaseSpring(
        response: HUDDragPhysics.softResponse,
        dampingFraction: HUDDragPhysics.softDamping
    )
}

/// What lifting the pointer off the HUD means.
public struct HUDDragRelease: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The HUD has been pulled free (or thrown free): where it lands is up
        /// to the dock it is carried to.
        case detach
        /// It was never pulled far enough, or was flicked back: it returns to
        /// the dock it came from.
        case snapBack
    }

    public var outcome: Outcome
    /// The extra travel the pointer's momentum would carry it beyond the
    /// release point, in the gesture's coordinate space.
    public var momentum: CGSize
    /// The translation at release plus ``momentum``: where the gesture was
    /// heading, which is what docking should be decided on.
    public var projectedTranslation: CGSize
    public var spring: HUDReleaseSpring

    public init(
        outcome: Outcome,
        momentum: CGSize,
        projectedTranslation: CGSize,
        spring: HUDReleaseSpring
    ) {
        self.outcome = outcome
        self.momentum = momentum
        self.projectedTranslation = projectedTranslation
        self.spring = spring
    }
}

/// How the HUD comes off the edge it is parked against.
///
/// A HUD that starts following the pointer on the first pixel of movement is a
/// window with a drag handle. This one is stuck to the machine, and pulled the
/// way a drop of liquid is pulled off a surface: for the first
/// ``detachDistance`` points the **anchored edge stays exactly where it is** —
/// on the bezel — while the body stretches away from it along the pull and necks
/// across it. Past that distance the edge lets go; the stretch is relaxed out
/// over ``blendDistance`` more points while the whole shape catches up to the
/// pointer, and from there it tracks the pointer one-to-one.
///
/// Every quantity is continuous across that threshold — offset *and* stretch.
/// The one constraint that decides the arithmetic: at the moment of release
/// the attached formulas and the free-flight formulas are not switched between
/// but **blended** with a smoothstep weight (``detachBlend(_:)``) that is zero at
/// the threshold, so neither the position nor the shape can jump, and the HUD
/// settles a constant ``detachLag`` behind the pointer.
///
/// Letting go is the other half (``release(translation:velocity:dock:reduceMotion:)``):
/// the pointer's velocity at that instant decides whether the shape goes with
/// momentum or settles back softly.
///
/// All of it is pure. The gesture is the one part of this feature that cannot
/// be judged from a screenshot, so it is the part that gets tests.
public enum HUDDragPhysics {
    /// How far the pointer travels before the HUD lets go of its dock.
    ///
    /// Long enough that a twitch on a trackpad does not unmoor the HUD, short
    /// enough that a deliberate pull is not a wrestling match. It is also the
    /// distance over which the stretch runs from nothing to full, so it doubles
    /// as the length of the "peeling" gesture.
    public static let detachDistance: CGFloat = 38

    /// How far past ``detachDistance`` the transition from "attached" to "free"
    /// takes.
    ///
    /// Short enough that the HUD is in free flight well before the pointer has
    /// gone twice the threshold, long enough that the stretch visibly relaxes
    /// as the edge peels away instead of vanishing the instant it lets go.
    public static let blendDistance: CGFloat = 24

    /// How much of the pointer's travel the HUD gives up while still attached.
    ///
    /// Feeds the rubber band below rather than being a plain multiplier: a flat
    /// fraction resists evenly, which reads as a heavy object, while the band
    /// resists *more* the further it is pulled, which reads as a stuck one.
    public static let resistance: CGFloat = 0.55

    /// Longest the shape gets along the pull, as a fraction of its own size.
    public static let maxStretch: CGFloat = 0.30

    /// How much it necks across the pull, relative to how much it elongates.
    ///
    /// Less than the elongation on purpose. Volume is not conserved here — the
    /// HUD is a silhouette, not a fluid — and squeezing it as hard as it
    /// stretches makes a thin dock disappear into a line before it detaches.
    public static let crossSqueeze: CGFloat = 0.45

    /// The classic rubber band: linear at the start, asymptotic at the limit.
    ///
    /// `f(0) = 0`, `f'(0) = resistance`, and `f(d)` never reaches
    /// `resistance × limit` however hard the band is pulled. That last property
    /// is the one that matters — it means no amount of overshoot can drag the
    /// attached HUD an unbounded distance from its dock.
    public static func rubberBand(
        _ distance: CGFloat,
        limit: CGFloat = detachDistance,
        resistance: CGFloat = resistance
    ) -> CGFloat {
        guard distance > 0, limit > 0, resistance > 0 else { return 0 }
        return (distance * resistance * limit) / (limit + resistance * distance)
    }

    /// The lag the HUD keeps once it has detached: everything the resistance
    /// swallowed on the way to the detach threshold.
    ///
    /// Subtracting exactly this from the pointer's distance puts the settled
    /// free-flight position at `rubberBand(detachDistance)` for a pointer
    /// standing at the threshold — the same travel the band had reached — so the
    /// HUD is never asked to cover more than the resistance already ate.
    public static var detachLag: CGFloat {
        detachDistance - rubberBand(detachDistance)
    }

    /// How far a pull has progressed from "stuck to the edge" (`0`) to "in free
    /// flight" (`1`).
    ///
    /// Exactly zero up to ``detachDistance`` and a smoothstep over the next
    /// ``blendDistance`` points, so both its value and its slope are zero where
    /// it starts: nothing about the HUD changes *speed* the instant it lets go,
    /// either.
    public static func detachBlend(_ distance: CGFloat) -> CGFloat {
        guard distance > detachDistance else { return 0 }
        let t = min(1, (distance - detachDistance) / blendDistance)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Dragging

    /// Turn a gesture translation into the HUD's offset and stretch.
    ///
    /// - Parameters:
    ///   - translation: the drag's translation, in points.
    ///   - dock: where the HUD is parked, which decides *which way* it can
    ///     stretch — a notch HUD hangs from the top edge and elongates
    ///     downward, an edge HUD hangs off a side and elongates inward.
    ///   - reduceMotion: when set, nothing deforms: the HUD stays `1×1` and
    ///     simply translates with the same resistance. Plain movement is what
    ///     remains of a gesture once the stretch is taken away.
    public static func resolve(
        translation: CGSize,
        dock: HUDDock,
        reduceMotion: Bool = false
    ) -> HUDDragState {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else {
            return HUDDragState(isActive: true)
        }

        let unit = CGSize(width: translation.width / distance, height: translation.height / distance)
        let away = dock.awayDirection
        // How much of the pull runs *away* from the anchored edge. Only that
        // part stretches anything: dragging a notch HUD sideways slides it
        // along the bezel; dragging it down peels it off.
        let awayComponent = unit.width * away.width + unit.height * away.height
        let alongEdge = CGSize(
            width: unit.width - away.width * awayComponent,
            height: unit.height - away.height * awayComponent
        )

        let band = rubberBand(distance)
        let freeTravel = distance - detachLag
        let blend = detachBlend(distance)

        // Attached, the edge is pinned: the only part of the pull that moves it
        // is the one *along* the bezel, resisted by the band. (Without a stretch
        // to show the pull, reduced motion falls back to moving the whole shape
        // by the band instead.) Detached, it follows the pointer less its lag,
        // and the blend carries one into the other.
        let attachedTravel = reduceMotion ? unit : alongEdge
        let offset = CGSize(
            width: attachedTravel.width * band * (1 - blend) + unit.width * freeTravel * blend,
            height: attachedTravel.height * band * (1 - blend) + unit.height * freeTravel * blend
        )
        let detached = distance >= detachDistance

        guard !reduceMotion else {
            return HUDDragState(offset: offset, isDetached: detached, isActive: true)
        }

        // The stretch follows the band, not the raw distance, so it builds fast
        // while the shape is still giving and stalls as the band tightens — and
        // it relaxes with the blend rather than snapping out at the threshold.
        let tension = min(1, band / rubberBand(detachDistance))
        let elongation = maxStretch * max(0, awayComponent) * tension * (1 - blend)
        let squeeze = 1 - elongation * crossSqueeze

        let stretch = dock.stretchesVertically
            ? CGSize(width: squeeze, height: 1 + elongation)
            : CGSize(width: 1 + elongation, height: squeeze)

        return HUDDragState(offset: offset, stretch: stretch, isDetached: detached, isActive: true)
    }

    // MARK: - Letting go

    /// Pointer speed (points per second) at which a release counts as a full
    /// flick for the purposes of the spring: bouncy, quick, carrying momentum.
    public static let flickSpeed: CGFloat = 900

    /// How far ahead the pointer's momentum is projected, in seconds.
    public static let momentumTime: CGFloat = 0.10

    /// The longest the projection is allowed to run, in points. A flick can
    /// carry the HUD to a neighbouring dock, but not across the display.
    public static let maxMomentum: CGFloat = 96

    /// Springs for the two ends of the speed range; releases in between blend.
    public static let softResponse: Double = 0.40
    public static let softDamping: Double = 0.82
    public static let flickResponse: Double = 0.34
    public static let flickDamping: Double = 0.52

    /// The largest relative initial velocity handed to the spring, so a
    /// near-zero distance to cover cannot ask for an absurd speed.
    public static let maxInitialVelocity: Double = 10

    /// Distances below this are treated as this long when turning a velocity
    /// into a relative one, for the same reason.
    private static let minVelocityBasis: CGFloat = 24

    /// Decide what lifting the pointer means, from where it is and how fast it
    /// is moving.
    ///
    /// The pointer's velocity is projected a short way ahead, and *that* point —
    /// not the exact release point — decides the outcome: a flick that has not
    /// yet gone ``detachDistance`` but is clearly leaving carries on and
    /// detaches; one that was pulled past the threshold and is being flicked
    /// back towards the dock snaps back. A slow release projects to almost
    /// where it is and behaves as before.
    ///
    /// The same speed picks the spring (``HUDReleaseSpring``): the faster the
    /// release, the springier and quicker it is, and the shape starts already
    /// moving at the pointer's speed instead of from rest.
    ///
    /// - Parameters:
    ///   - translation: the drag's translation at the moment of release.
    ///   - velocity: the pointer's velocity in points per second, in the same
    ///     coordinate space as `translation`.
    ///   - dock: where the HUD is parked.
    ///   - reduceMotion: suppresses the initial velocity, since nothing is
    ///     animated in that mode; the momentum still counts for docking, which
    ///     is a decision and not an effect.
    public static func release(
        translation: CGSize,
        velocity: CGSize,
        dock: HUDDock,
        reduceMotion: Bool = false
    ) -> HUDDragRelease {
        var momentum = CGSize(width: velocity.width * momentumTime, height: velocity.height * momentumTime)
        let reach = hypot(momentum.width, momentum.height)
        if reach > maxMomentum {
            momentum = CGSize(width: momentum.width * maxMomentum / reach, height: momentum.height * maxMomentum / reach)
        }
        let projected = CGSize(width: translation.width + momentum.width, height: translation.height + momentum.height)
        let outcome: HUDDragRelease.Outcome = hypot(projected.width, projected.height) >= detachDistance
            ? .detach
            : .snapBack

        let speed = hypot(velocity.width, velocity.height)
        let flick = Double(min(1, speed / flickSpeed))
        let response = softResponse + (flickResponse - softResponse) * flick
        let damping = softDamping + (flickDamping - softDamping) * flick

        // Relative to the distance still to travel home. The offset is what the
        // spring animates from, so it is also what the velocity is measured
        // against: pointer speed along the line back to the dock, divided by
        // how far that line is.
        var initialVelocity = 0.0
        let offset = resolve(translation: translation, dock: dock, reduceMotion: reduceMotion).offset
        let travel = hypot(offset.width, offset.height)
        if !reduceMotion, travel > 0.5 {
            let towardHome = -(velocity.width * offset.width + velocity.height * offset.height) / travel
            let relative = Double(towardHome / max(travel, minVelocityBasis))
            initialVelocity = min(maxInitialVelocity, max(-maxInitialVelocity, relative))
        }

        return HUDDragRelease(
            outcome: outcome,
            momentum: momentum,
            projectedTranslation: projected,
            spring: HUDReleaseSpring(response: response, dampingFraction: damping, initialVelocity: initialVelocity)
        )
    }
}

public extension HUDDock {
    /// Whether the dock's free axis is vertical — that is, whether pulling
    /// *down* is what peels this HUD off the machine.
    ///
    /// True for the notch, which is anchored along the top edge. False for the
    /// edge docks, which are anchored along a side and elongate inward.
    var stretchesVertically: Bool { self == .notch }

    /// The unit vector, in view coordinates (y grows downward), that points
    /// from the dock's anchored edge into the display — the direction a pull
    /// has to run to peel the HUD off.
    ///
    /// Down for the notch, right for a HUD on the left edge, left for one on the
    /// right edge.
    var awayDirection: CGSize {
        switch self {
        case .notch: CGSize(width: 0, height: 1)
        case .left: CGSize(width: 1, height: 0)
        case .right: CGSize(width: -1, height: 0)
        }
    }
}

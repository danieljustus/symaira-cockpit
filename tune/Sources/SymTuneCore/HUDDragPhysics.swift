import CoreGraphics
import Foundation

/// What a drag is currently doing to the HUD's shape and position.
///
/// Returned by ``HUDDragPhysics/resolve(translation:dock:)`` and applied by the
/// view as an offset and a scale. Keeping it a value type with no AppKit in it
/// is what lets the interesting half of the gesture — the part where the HUD is
/// resisting — be checked in tests rather than by eye.
public struct HUDDragState: Equatable, Sendable {
    /// Where the HUD has actually moved to, which is **not** the pointer's
    /// translation while the HUD is still attached.
    public var offset: CGSize
    /// Scale factors applied at the dock's own anchor edge. `1×1` at rest.
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

/// How the HUD comes off the edge it is parked against.
///
/// A HUD that starts following the pointer on the first pixel of movement is a
/// window with a drag handle. This one is stuck to the machine: for the first
/// ``detachDistance`` points it *resists* — it moves a fraction of the distance
/// the pointer has, and it stretches along the pull while necking across it,
/// the way anything peeled off a surface does. Past that distance it lets go,
/// the stretch springs out, and from there it tracks the pointer exactly.
///
/// The two halves have to meet without a jump, which is the one constraint that
/// decides the arithmetic: at the moment of release the resisted distance is
/// carried forward as a constant lag, so the HUD is behind the pointer by
/// exactly the amount the resistance ate and never teleports to catch up.
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
    /// Subtracting exactly this from the pointer's distance is what makes the
    /// two regimes continuous — at `distance == detachDistance` both branches
    /// of ``resolve(translation:dock:)`` return the same travel.
    public static var detachLag: CGFloat {
        detachDistance - rubberBand(detachDistance)
    }

    /// Turn a gesture translation into the HUD's offset and stretch.
    ///
    /// - Parameters:
    ///   - translation: the drag's translation, in points.
    ///   - dock: where the HUD is parked, which decides *which way* it can
    ///     stretch — a notch HUD hangs from the top edge and elongates
    ///     downward, an edge HUD hangs off a side and elongates inward.
    public static func resolve(translation: CGSize, dock: HUDDock) -> HUDDragState {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else {
            return HUDDragState(isActive: true)
        }

        let unitX = translation.width / distance
        let unitY = translation.height / distance

        let detached = distance >= detachDistance
        let travel = detached
            ? distance - detachLag
            : rubberBand(distance)

        let offset = CGSize(width: unitX * travel, height: unitY * travel)

        // Detached, the shape is in free flight and carries no tension. The
        // spring in the view is what takes the stretch back out, so returning
        // to 1×1 here is a target rather than a jump.
        guard !detached else {
            return HUDDragState(offset: offset, isDetached: true, isActive: true)
        }

        // Only the component of the pull that runs *away* from the anchored
        // edge stretches anything. Dragging a notch HUD sideways slides it
        // along the bezel; dragging it down peels it off.
        let along = dock.stretchesVertically ? abs(unitY) : abs(unitX)
        let elongation = min(1, distance / detachDistance) * maxStretch * along
        let squeeze = 1 - elongation * crossSqueeze

        let stretch = dock.stretchesVertically
            ? CGSize(width: squeeze, height: 1 + elongation)
            : CGSize(width: 1 + elongation, height: squeeze)

        return HUDDragState(offset: offset, stretch: stretch, isActive: true)
    }
}

public extension HUDDock {
    /// Whether the dock's free axis is vertical — that is, whether pulling
    /// *down* is what peels this HUD off the machine.
    ///
    /// True for the notch, which is anchored along the top edge. False for the
    /// edge docks, which are anchored along a side and elongate inward.
    var stretchesVertically: Bool { self == .notch }
}

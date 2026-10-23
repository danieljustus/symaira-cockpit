import SwiftUI
import SymCockpitCore

/// Every curve the HUD moves on.
///
/// Collected in one place because the HUD's whole claim is that it is one
/// object with one weight, and nothing gives that away faster than two of its
/// parts easing differently. Before this there was a single spring used for
/// everything, which had the opposite problem: a hover that took as long as a
/// dock change feels sluggish, because the two gestures are asking for
/// different things.
///
/// So: one family, a handful of tunings, each named for the gesture it answers.
enum HUDMotion {
    /// Hovering on and off. The shortest curve here — the peek has to feel like
    /// a consequence of the pointer arriving, not like a response to it.
    static let peek = Animation.spring(response: 0.26, dampingFraction: 0.84)

    /// Opening and closing the card. Longer, and allowed a little overshoot:
    /// this one the user asked for with a click, and it should look like
    /// something with mass unfolding.
    static let expand = Animation.spring(response: 0.44, dampingFraction: 0.78)

    /// Travelling between docks. The longest, because it crosses the display
    /// and a fast curve over that distance reads as a jump cut.
    static let dock = Animation.spring(response: 0.52, dampingFraction: 0.80)

    /// Following the pointer during a drag.
    ///
    /// Barely a spring at all — it exists to take the jitter off raw pointer
    /// samples without putting the HUD behind the cursor. Anything slower and
    /// the object feels like it is being towed through syrup.
    static let track = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.86)

    /// Springing the HUD back to the dock when a drag is released or abandoned.
    ///
    /// Not a fixed curve: ``HUDDragPhysics/release(translation:velocity:dock:reduceMotion:)``
    /// tunes it from the pointer's speed at the moment of release. A flick is
    /// the bounciest curve in the set and starts out already moving at the
    /// pointer's pace, so the shape carries on a little before the spring wins
    /// it back; a slow let-go settles softly. Either way the overshoot is the
    /// whole point — it is what makes the preceding resistance read as
    /// elasticity rather than as lag.
    ///
    /// An interpolating spring because it accepts an initial velocity, which is
    /// what lets the animation continue the gesture's momentum instead of
    /// starting from a standstill.
    static func release(_ spring: HUDReleaseSpring) -> Animation {
        .interpolatingSpring(
            Spring(response: spring.response, dampingRatio: spring.dampingFraction),
            initialVelocity: spring.initialVelocity
        )
    }

    /// The same spring without the velocity, for the stretch coming back out.
    ///
    /// The pointer's speed is a statement about where the shape is going, not
    /// about how fast it is un-stretching, so only the offset gets it. The
    /// stretch still shares the response and damping, so both halves of the
    /// shape settle on one beat.
    static func recoil(_ spring: HUDReleaseSpring) -> Animation {
        .interpolatingSpring(Spring(response: spring.response, dampingRatio: spring.dampingFraction))
    }

    /// Rolling one readout's digits over to the next.
    static let value = Animation.snappy(duration: 0.28)
}

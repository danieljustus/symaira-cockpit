import SwiftUI

/// Every curve the HUD moves on.
///
/// Collected in one place because the HUD's whole claim is that it is one
/// object with one weight, and nothing gives that away faster than two of its
/// parts easing differently. Before this there was a single spring used for
/// everything, which had the opposite problem: a hover that took as long as a
/// dock change feels sluggish, because the two gestures are asking for
/// different things.
///
/// So: one family, four tunings, each named for the gesture it answers.
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

    /// Springing back to the dock when a drag is released or abandoned.
    ///
    /// Deliberately the bounciest curve in the set. This is the moment the
    /// stretched shape snaps back against the bezel, and the overshoot is the
    /// whole point — it is what makes the preceding resistance read as
    /// elasticity rather than as lag.
    static let release = Animation.spring(response: 0.36, dampingFraction: 0.58)

    /// Rolling one readout's digits over to the next.
    static let value = Animation.snappy(duration: 0.28)
}

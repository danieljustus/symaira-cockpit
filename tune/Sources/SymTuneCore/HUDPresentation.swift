import Foundation

/// How far the HUD is open.
///
/// Three stops, not two. The pair the HUD shipped with — parked or fully open —
/// forced one decision to carry two jobs: the pointer merely *passing* the
/// cutout had to either do nothing or throw the whole card open. Neither is
/// what a glance wants.
///
/// - ``collapsed`` is the resting shape. It is the illusion: black, flush with
///   the bezel, carrying at most a number or two.
/// - ``peek`` is what hovering earns. Slightly wider shoulders, a few points of
///   drop, one or two more readouts. It answers a glance without taking the
///   screen, and it costs nothing to leave again.
/// - ``expanded`` is what a click earns. The full card, every configured item,
///   the action buttons.
///
/// The order matters and is the type's whole point: an item is configured with
/// the *earliest* stage it may appear in, and is drawn whenever the current
/// presentation has reached it. That is why this is `Comparable` — the
/// visibility rule is literally `presentation >= item.stage`.
public enum HUDPresentation: String, CaseIterable, Comparable, Sendable {
    case collapsed
    case peek
    case expanded

    /// Position in the sequence, which is what the ordering compares.
    public var rank: Int {
        switch self {
        case .collapsed: 0
        case .peek: 1
        case .expanded: 2
        }
    }

    public static func < (lhs: HUDPresentation, rhs: HUDPresentation) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Whether the HUD is showing more than its resting shape.
    public var isOpen: Bool { self > .collapsed }

    public var displayName: String {
        switch self {
        case .collapsed: "Always"
        case .peek: "On hover"
        case .expanded: "When opened"
        }
    }

    /// What the settings row says the choice means, in the user's terms.
    ///
    /// Phrased from the item's point of view rather than the HUD's: the user is
    /// deciding when *this readout* turns up, not naming a state machine.
    public var settingsCaption: String {
        switch self {
        case .collapsed: "Visible even when the HUD is parked"
        case .peek: "Appears when the pointer reaches the HUD"
        case .expanded: "Appears only after the HUD is clicked open"
        }
    }
}

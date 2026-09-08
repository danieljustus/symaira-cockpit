import CoreGraphics
import Foundation

/// Which of the three heights an edge dock sits at.
///
/// Three and not a free position: a HUD the user can park anywhere is a HUD
/// they have to aim at, and one that is never quite aligned with the last time.
/// Three stops snap, and a snapped HUD is findable by muscle memory.
public enum HUDSlot: String, CaseIterable, Sendable {
    case top
    case center
    case bottom

    public var displayName: String {
        switch self {
        case .top: "Top"
        case .center: "Middle"
        case .bottom: "Bottom"
        }
    }
}

/// Where the HUD is docked.
///
/// The camera cutout and the screen edges are the same HUD in two shapes, not
/// two features: `.notch` is horizontal and grows downward, an edge dock is
/// vertical and grows inward. Everything else — the content, the model, the
/// hover-to-expand — is shared.
public enum HUDDock: Equatable, Hashable, Sendable, CaseIterable {
    case notch
    case left(HUDSlot)
    case right(HUDSlot)

    public static var allCases: [HUDDock] {
        [.notch]
            + HUDSlot.allCases.map(HUDDock.left)
            + HUDSlot.allCases.map(HUDDock.right)
    }

    /// The edge docks alone — the targets a drag can snap to besides the notch.
    public static var edgeCases: [HUDDock] {
        allCases.filter { $0 != .notch }
    }

    public var isEdge: Bool { self != .notch }

    /// Whether the dock hangs on the trailing edge. Drives which way the
    /// expanded card grows and which side its corners are rounded on.
    public var isRightEdge: Bool {
        if case .right = self { return true }
        return false
    }

    public var slot: HUDSlot? {
        switch self {
        case .notch: nil
        case let .left(slot), let .right(slot): slot
        }
    }

    // MARK: - Persistence

    /// Stable string form for `UserDefaults`.
    ///
    /// Spelled out rather than derived, because it is written to a user's
    /// defaults and must survive any later renaming of the cases.
    public var storageKey: String {
        switch self {
        case .notch: "notch"
        case let .left(slot): "left.\(slot.rawValue)"
        case let .right(slot): "right.\(slot.rawValue)"
        }
    }

    public init?(storageKey: String) {
        if storageKey == "notch" {
            self = .notch
            return
        }
        let parts = storageKey.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let slot = HUDSlot(rawValue: String(parts[1])) else { return nil }
        switch parts[0] {
        case "left": self = .left(slot)
        case "right": self = .right(slot)
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .notch: "Notch"
        case let .left(slot): "Left edge — \(slot.displayName)"
        case let .right(slot): "Right edge — \(slot.displayName)"
        }
    }
}

/// Where a docked HUD's panel goes, collapsed and expanded, for every dock.
///
/// This generalises ``NotchLayout`` from the one position it knew to seven, and
/// it keeps that layer rather than replacing it: the notch case is genuinely
/// special — its geometry is dictated by a hole in the display that
/// ``NotchLayout`` already measures — while an edge dock is free-standing and
/// only has to stay on screen.
///
/// Everything is returned in the global, bottom-left-origin screen coordinates
/// `NSScreen.frame` uses, so the controller can convert once into the
/// stage panel's local space and hand SwiftUI a rectangle to animate towards.
///
/// The whole file is AppKit-free on purpose: the placement rules are the part
/// most likely to be wrong, and they are the part that can be tested without a
/// display attached.
public enum HUDDockLayout {
    // MARK: - Edge metrics

    /// Visible width of a collapsed edge dock.
    ///
    /// A sliver, not a pill. Parked, the HUD is meant to read as a thickening
    /// of the display's own bezel rather than as a window sitting near it, and
    /// anything wide enough to carry a number is too wide to pass for bezel.
    public static let edgeCollapsedWidth: CGFloat = 7
    /// Height of a collapsed edge dock.
    public static let edgeCollapsedHeight: CGFloat = 112
    /// How wide the *reactive* strip along the edge is, as opposed to the drawn
    /// sliver.
    ///
    /// Seven points is a hard thing to hit and an easy thing to miss on the way
    /// past, so the region that expands the HUD is wider than the region that
    /// draws it. The user aims at the edge of the screen — which needs no aim
    /// at all, since the pointer stops there — and the HUD opens.
    public static let edgeHoverWidth: CGFloat = 26
    /// Width the expanded edge card asks for.
    public static let edgeExpandedWidth: CGFloat = 288
    /// Content height the expanded edge card asks for.
    public static let edgeExpandedHeight: CGFloat = 268
    /// Gap between an edge dock and the screen edge it hangs on.
    ///
    /// Zero, and deliberately so: the illusion is that the HUD is part of the
    /// display's frame, and a frame with a gap behind it is a window. This is
    /// the same trick the notch dock plays against the camera cutout.
    public static let edgeInset: CGFloat = 0
    /// Space kept between an edge dock and the top and bottom of its band.
    public static let edgeMargin: CGFloat = 16
    /// How close the pointer must come to a dock during a drag before it is
    /// pulled in. Generous, because the user is aiming at a region, not a point.
    public static let snapRadius: CGFloat = 160

    // MARK: - Availability

    /// Whether this display can host the given dock.
    ///
    /// Every display can host every edge dock. Only a display with a camera
    /// cutout can host `.notch` — which is what makes the edge docks worth
    /// having: they bring the HUD to the Mac minis and external monitors that
    /// ``NotchLayout`` has to refuse.
    public static func supports(_ dock: HUDDock, on metrics: NotchScreenMetrics) -> Bool {
        switch dock {
        case .notch: NotchLayout.supportsHUD(metrics)
        case .left, .right: usableBand(metrics) != nil
        }
    }

    /// The dock to fall back to when the stored one cannot be shown — a
    /// `.notch` preference on a display that has no cutout, most often a
    /// MacBook driving an external monitor with the lid shut.
    ///
    /// The right edge at centre height, not "no HUD": the user asked for a HUD,
    /// and the edge is the shape of it that every display can render.
    public static func effective(_ dock: HUDDock, on metrics: NotchScreenMetrics) -> HUDDock? {
        if supports(dock, on: metrics) { return dock }
        let fallback = HUDDock.right(.center)
        return supports(fallback, on: metrics) ? fallback : nil
    }

    /// The vertical range an edge dock may occupy: the display, less the menu
    /// bar at the top and one margin at each end.
    ///
    /// `nil` when the display is too short to hold a collapsed pill inside it —
    /// which no real display is, but the frames below are only correct while it
    /// holds, so it is checked rather than assumed.
    public static func usableBand(_ metrics: NotchScreenMetrics) -> ClosedRange<CGFloat>? {
        let lower = metrics.frame.minY + edgeMargin
        let upper = metrics.frame.maxY - metrics.menuBarHeight - edgeMargin
        guard upper - lower >= edgeCollapsedHeight else { return nil }
        return lower...upper
    }

    // MARK: - Frames

    /// The collapsed frame for a dock, or `nil` when this display cannot host it.
    public static func collapsedFrame(
        _ dock: HUDDock,
        on metrics: NotchScreenMetrics
    ) -> CGRect? {
        switch dock {
        case .notch:
            return NotchLayout.collapsedFrame(metrics)
        case let .left(slot):
            return edgeFrame(
                slot: slot,
                onRight: false,
                width: edgeCollapsedWidth,
                height: edgeCollapsedHeight,
                metrics: metrics
            )
        case let .right(slot):
            return edgeFrame(
                slot: slot,
                onRight: true,
                width: edgeCollapsedWidth,
                height: edgeCollapsedHeight,
                metrics: metrics
            )
        }
    }

    /// The expanded frame for a dock, or `nil` when this display cannot host it.
    ///
    /// - Parameter contentHeight: height the card's content wants. Clamped to
    ///   the usable band, so a tall card on a short display shrinks rather than
    ///   hanging off the end.
    public static func expandedFrame(
        _ dock: HUDDock,
        on metrics: NotchScreenMetrics,
        contentHeight: CGFloat? = nil
    ) -> CGRect? {
        switch dock {
        case .notch:
            return NotchLayout.expandedFrame(
                metrics,
                contentHeight: contentHeight ?? NotchLayout.preferredExpandedHeight
            )
        case let .left(slot):
            return expandedEdgeFrame(slot: slot, onRight: false, contentHeight: contentHeight, metrics: metrics)
        case let .right(slot):
            return expandedEdgeFrame(slot: slot, onRight: true, contentHeight: contentHeight, metrics: metrics)
        }
    }

    private static func expandedEdgeFrame(
        slot: HUDSlot,
        onRight: Bool,
        contentHeight: CGFloat?,
        metrics: NotchScreenMetrics
    ) -> CGRect? {
        guard let band = usableBand(metrics) else { return nil }
        let wanted = max(contentHeight ?? edgeExpandedHeight, edgeCollapsedHeight)
        let height = min(wanted, band.upperBound - band.lowerBound)
        // Never narrower than the screen allows: the card is clamped before it
        // is placed, so a narrow display gets a narrow card, not one hanging
        // off the far side.
        let width = min(edgeExpandedWidth, max(edgeCollapsedWidth, metrics.frame.width - edgeInset * 2))
        return edgeFrame(
            slot: slot,
            onRight: onRight,
            width: width,
            height: height,
            metrics: metrics
        )
    }

    /// Place a rectangle of the given size against one vertical edge.
    ///
    /// The slot anchors it: `.top` and `.bottom` pin the corresponding end of
    /// the rectangle to its end of the band, `.center` centres it. That anchor
    /// is what makes expansion look right — a top-docked card grows downward, a
    /// bottom-docked one grows upward, and a centred one grows both ways —
    /// because growing the height re-runs this with the same anchor.
    private static func edgeFrame(
        slot: HUDSlot,
        onRight: Bool,
        width: CGFloat,
        height: CGFloat,
        metrics: NotchScreenMetrics
    ) -> CGRect? {
        guard let band = usableBand(metrics) else { return nil }
        let clampedHeight = min(height, band.upperBound - band.lowerBound)

        let y: CGFloat = switch slot {
        case .top: band.upperBound - clampedHeight
        case .center: band.lowerBound + (band.upperBound - band.lowerBound - clampedHeight) / 2
        case .bottom: band.lowerBound
        }

        let x = onRight
            ? metrics.frame.maxX - edgeInset - width
            : metrics.frame.minX + edgeInset

        return CGRect(x: x, y: y, width: width, height: clampedHeight)
    }

    /// The strip that reacts to the pointer while `dock` is collapsed.
    ///
    /// The collapsed frame widened inward to ``edgeHoverWidth`` — see there for
    /// why it is not simply the drawn frame. The notch dock is its own answer:
    /// its collapsed frame is already a comfortable target.
    public static func hoverFrame(
        _ dock: HUDDock,
        on metrics: NotchScreenMetrics
    ) -> CGRect? {
        guard let frame = collapsedFrame(dock, on: metrics) else { return nil }
        guard dock.isEdge else { return frame }
        let width = max(frame.width, edgeHoverWidth)
        return CGRect(
            x: dock.isRightEdge ? frame.maxX - width : frame.minX,
            y: frame.minY,
            width: width,
            height: frame.height
        )
    }

    // MARK: - Snapping

    /// The dock a drag ending at `point` should land in, or `nil` when the
    /// pointer is too far from every one of them.
    ///
    /// Distance is measured to the centre of each dock's *collapsed* frame, so
    /// the target the user is aiming at is the shape they will get, and only
    /// docks this display can actually host are offered — dragging towards the
    /// notch on an external monitor finds nothing there rather than snapping
    /// into a cutout that does not exist.
    ///
    /// - Returns: the nearest dock within ``snapRadius``, or `nil`.
    public static func nearestDock(
        to point: CGPoint,
        on metrics: NotchScreenMetrics,
        radius: CGFloat = snapRadius
    ) -> HUDDock? {
        var best: (dock: HUDDock, distance: CGFloat)?
        for dock in HUDDock.allCases {
            guard let frame = collapsedFrame(dock, on: metrics) else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let distance = hypot(point.x - centre.x, point.y - centre.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (dock, distance)
            }
        }
        return best?.dock
    }
}

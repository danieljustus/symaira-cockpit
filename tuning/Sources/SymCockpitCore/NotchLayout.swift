import CoreGraphics
import Foundation

/// The measurements the notch HUD needs from one display.
///
/// Kept free of AppKit so the geometry is testable without a screen: the
/// controller reads `NSScreen.frame`, `safeAreaInsets.top` and the two
/// `auxiliaryTop*Area` rectangles once and hands the numbers over.
///
/// Coordinates are the global (bottom-left origin) space `NSScreen.frame` and
/// `NSWindow.setFrame` both use, so a frame computed here can be applied to a
/// panel unchanged.
public struct NotchScreenMetrics: Equatable, Sendable {
    /// The display's full frame, in global screen coordinates.
    public var frame: CGRect
    /// Height of the menu bar strip — `NSScreen.safeAreaInsets.top`. Zero on a
    /// display without a notch.
    public var menuBarHeight: CGFloat
    /// Width of the usable strip left of the cutout
    /// (`NSScreen.auxiliaryTopLeftArea?.width`); `nil` when the display has no
    /// cutout.
    public var leftAuxiliaryWidth: CGFloat?
    /// Width of the usable strip right of the cutout
    /// (`NSScreen.auxiliaryTopRightArea?.width`); `nil` when the display has
    /// no cutout.
    public var rightAuxiliaryWidth: CGFloat?

    public init(
        frame: CGRect,
        menuBarHeight: CGFloat,
        leftAuxiliaryWidth: CGFloat?,
        rightAuxiliaryWidth: CGFloat?
    ) {
        self.frame = frame
        self.menuBarHeight = menuBarHeight
        self.leftAuxiliaryWidth = leftAuxiliaryWidth
        self.rightAuxiliaryWidth = rightAuxiliaryWidth
    }
}

/// Where the notch HUD's panel goes, collapsed and expanded.
///
/// The camera cutout has no pixels — nothing can be drawn *in* it. The Dynamic
/// Island effect comes from a black, bottom-rounded panel drawn *around and
/// below* the cutout, so the two read as one shape. That makes the geometry the
/// whole trick, and the reason it lives here, in a pure enum with tests, rather
/// than inline in the controller:
///
/// - The panel always spans the cutout plus a **shoulder** on each side. The
///   shoulders are the only place collapsed content can appear.
/// - The shoulders are clamped: they are carved out of the strips that hold the
///   frontmost app's menu titles (left) and everyone's status items (right),
///   and macOS offers no way to learn what is already there. A bounded shoulder
///   keeps the overlap to the pixels immediately beside the cutout, which are
///   the least likely to be occupied.
/// - Expanded, the panel is centred on the **cutout**, not on the screen, and
///   clamped inside the display.
public enum NotchLayout {
    /// Shoulder width per side the HUD asks for when there is room.
    ///
    /// Deliberately snug. Every point of shoulder is a point taken from the
    /// menu titles on the left and the status items on the right, and the right
    /// side is the only one an app can claim back (see the spacer status item
    /// in `StatusBarController`) — so the width is set by what a readout
    /// actually needs, not by what looks comfortable.
    ///
    /// 48 points, down from 64 (issue #374). Measured with the shoulder's own
    /// readout (a 10 pt SF Symbol, 3 pt gap, then the value in Google Sans Flex
    /// 11.5/500 with tabular digits) plus its 4 pt padding per side, the long
    /// strings never fitted 64: `15.2 GB` needs 71 pt and `485.0 GB` 79 pt.
    /// The resting shoulder therefore shows the compact form of the value (see
    /// `MetricFormatting.compactReadout`). Natural width of the whole item, and
    /// the shoulder it would need to show it unscaled (item + 8 pt padding):
    ///
    /// | readout         | item  | shoulder |
    /// | --------------- | ----- | -------- |
    /// | `37%`           | 38    | 46       |
    /// | `15G`, `99G`    | 41    | 49       |
    /// | `7.9G`          | 44    | 52       |
    /// | `100%`          | 45    | 53       |
    /// | `128G`, `485G`  | 48–49 | 56–57    |
    ///
    /// At 48 the usual readouts (`37%`, `15G`) fit as they are or within a
    /// point of it; the rare wide ones scale their text instead of widening the
    /// panel or being clipped — about 0.85 for `100%` and 0.75 for
    /// three-digit gigabytes, above the 0.7 floor `HUDCompactItem` allows.
    ///
    /// The strip has since moved to a lighter 10.5/400 value with a 9 pt
    /// symbol, and the compact form keeps the full unit behind a narrow gap
    /// (`485 GB`, `37 %`). Measured the same way with a proxy face, that is
    /// about 49 pt for `485 GB` and 43 pt for `15 GB` / `100 %` — the same
    /// scaling as above. A rate such as `1.9 MB/s` (about 55 pt) would hit the
    /// 0.7 floor on a parked shoulder; the default layout keeps the network
    /// readout at the peek, where the shoulder is wide enough.
    public static let preferredShoulder: CGFloat = 48
    /// Below this the shoulders cannot hold a readout, so the HUD stays off.
    ///
    /// The narrowest useful readout is an icon and a two-digit percentage
    /// (`37%`: 12 pt symbol, 3 pt gap, 22.5 pt of text) with its text at the
    /// 0.7 scale floor, which is 38.75 pt including padding.
    public static let minimumShoulder: CGFloat = 40
    /// Shoulder width the HUD grows to while the pointer is on it.
    ///
    /// Two and a half times the resting width, which is what buys the peek a
    /// second readout per side. The overlap it costs is borrowed rather than taken:
    /// it lasts as long as the pointer is there, and the pointer being there is
    /// itself evidence the user is not reading the menu titles underneath.
    public static let preferredPeekShoulder: CGFloat = 116
    /// Share of one auxiliary strip the *peeking* HUD may take.
    ///
    /// Larger than ``shoulderShareOfAuxiliary`` for the reason above, and still
    /// short of the whole strip: the app's own menu title sits at the far left,
    /// and covering it even briefly is disorienting.
    public static let peekShareOfAuxiliary: CGFloat = 0.78
    /// How far the peeking HUD hangs below the menu bar strip.
    ///
    /// Small, and not content: the readouts stay centred in the menu bar strip
    /// where they were. This is silhouette alone — the few points of drop that
    /// let the bottom corners round visibly, which is what makes the shape read
    /// as having swollen rather than as having been swapped.
    public static let peekDrop: CGFloat = 9
    /// Share of one auxiliary strip the HUD is willing to take. The rest is
    /// left to the menu titles and status items that live there.
    public static let shoulderShareOfAuxiliary: CGFloat = 0.4
    /// Width the expanded card asks for.
    public static let preferredExpandedWidth: CGFloat = 440
    /// Content height below the menu bar strip when expanded.
    public static let preferredExpandedHeight: CGFloat = 196
    /// Space kept between the expanded card and the screen edges.
    public static let screenMargin: CGFloat = 12

    /// Width of the camera cutout, or `nil` when the display has none.
    ///
    /// A notched display reports both auxiliary areas and a non-zero safe-area
    /// inset; the cutout is what is left of the width between them. Anything
    /// that fails those checks — every external display, every Mac mini, every
    /// pre-2021 MacBook — has no notch and gets no HUD.
    public static func notchWidth(_ metrics: NotchScreenMetrics) -> CGFloat? {
        guard metrics.menuBarHeight > 0,
              metrics.frame.width > 0,
              let left = metrics.leftAuxiliaryWidth,
              let right = metrics.rightAuxiliaryWidth,
              left > 0, right > 0
        else { return nil }

        let width = metrics.frame.width - left - right
        guard width > 0 else { return nil }
        return width
    }

    /// Whether a HUD can be placed on this display at all.
    public static func supportsHUD(_ metrics: NotchScreenMetrics) -> Bool {
        collapsedFrame(metrics) != nil
    }

    /// Shoulder width per side: the preferred width, capped by the share of the
    /// narrower auxiliary strip the HUD may claim. `nil` when what remains is
    /// too small to render into.
    public static func shoulderWidth(_ metrics: NotchScreenMetrics) -> CGFloat? {
        guard notchWidth(metrics) != nil,
              let left = metrics.leftAuxiliaryWidth,
              let right = metrics.rightAuxiliaryWidth
        else { return nil }

        let budget = min(left, right) * shoulderShareOfAuxiliary
        let shoulder = min(preferredShoulder, budget)
        guard shoulder >= minimumShoulder else { return nil }
        return shoulder
    }

    /// The collapsed panel: the cutout plus one shoulder on each side, filling
    /// the menu bar strip.
    public static func collapsedFrame(_ metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = notchWidth(metrics),
              let shoulder = shoulderWidth(metrics),
              let left = metrics.leftAuxiliaryWidth
        else { return nil }

        return CGRect(
            x: metrics.frame.minX + left - shoulder,
            y: metrics.frame.maxY - metrics.menuBarHeight,
            width: notch + shoulder * 2,
            height: metrics.menuBarHeight
        )
    }

    /// Shoulder width while the HUD is peeking, or `nil` when the display
    /// cannot host the HUD at all.
    ///
    /// Never narrower than the resting shoulder: on a display whose auxiliary
    /// strips are tight, the peek simply does not grow rather than shrinking
    /// the readouts that were already there.
    public static func peekShoulderWidth(_ metrics: NotchScreenMetrics) -> CGFloat? {
        guard let resting = shoulderWidth(metrics),
              let left = metrics.leftAuxiliaryWidth,
              let right = metrics.rightAuxiliaryWidth
        else { return nil }

        let budget = min(left, right) * peekShareOfAuxiliary
        return max(resting, min(preferredPeekShoulder, budget))
    }

    /// The peeking panel: the collapsed one with wider shoulders and a few
    /// points of drop below the menu bar strip.
    public static func peekFrame(_ metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = notchWidth(metrics),
              let shoulder = peekShoulderWidth(metrics),
              let left = metrics.leftAuxiliaryWidth
        else { return nil }

        let height = metrics.menuBarHeight + peekDrop
        return CGRect(
            x: metrics.frame.minX + left - shoulder,
            y: metrics.frame.maxY - height,
            width: notch + shoulder * 2,
            height: height
        )
    }

    /// The expanded card: centred on the cutout, hanging from the top edge,
    /// never narrower than the collapsed panel and never past the screen
    /// margins.
    public static func expandedFrame(
        _ metrics: NotchScreenMetrics,
        contentHeight: CGFloat = preferredExpandedHeight
    ) -> CGRect? {
        guard let collapsed = collapsedFrame(metrics),
              let notch = notchWidth(metrics),
              let left = metrics.leftAuxiliaryWidth
        else { return nil }

        let available = max(collapsed.width, metrics.frame.width - screenMargin * 2)
        let width = min(max(preferredExpandedWidth, collapsed.width), available)
        let height = min(
            metrics.menuBarHeight + max(0, contentHeight),
            metrics.frame.height
        )

        let cutoutCentre = metrics.frame.minX + left + notch / 2
        let lowerBound = metrics.frame.minX + screenMargin
        let upperBound = metrics.frame.maxX - screenMargin - width
        // A screen too narrow for the margins would invert the bounds; the
        // cutout's own centring is the better answer there than a clamp that
        // pins the card to a nonsensical edge.
        let x = upperBound >= lowerBound
            ? min(max(cutoutCentre - width / 2, lowerBound), upperBound)
            : cutoutCentre - width / 2

        return CGRect(
            x: x,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
    }
}

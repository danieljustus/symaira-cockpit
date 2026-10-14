import SwiftUI

/// The silhouette of anything the HUD parks against the display's frame.
///
/// The corners that meet the frame are **concave**: the shape flares outward as
/// it reaches the edge, the way the camera cutout flares into the bezel above
/// it. That single detail is what decides whether the HUD reads as part of the
/// machine. A convex corner there draws its own outline against the edge — and
/// the moment the eye can trace an outline all the way round, it is looking at
/// a window parked near the bezel rather than at a shape cut into it.
///
/// The flare is drawn *outside* the content's frame: hand it a rect grown by
/// ``HUDBezel/cornerRadius`` on the two sides that run into the edge, so the
/// readouts keep the width the layout budgeted for them and only the silhouette
/// spills over.
struct HUDBezelShape: InsettableShape {
    /// Which side of the display the shape is parked against. The two corners
    /// on that side flare; the two on the free side are ordinary convex ones.
    enum Anchor {
        case top
        case leading
        case trailing
    }

    let anchor: Anchor
    /// Radius of the concave fillets where the shape runs into the frame.
    let flare: CGFloat
    /// Radius of the convex corners at the free end.
    let innerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> HUDBezelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard bounds.width > 0, bounds.height > 0 else { return Path() }

        switch anchor {
        case .top:
            return topAnchoredPath(in: bounds)
        case .trailing:
            // A quarter turn clockwise takes the top edge onto the trailing
            // one, so the same path serves both — built in a rect with its
            // dimensions swapped, then rotated back into place.
            return topAnchoredPath(in: CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width))
                .applying(
                    CGAffineTransform(translationX: bounds.maxX, y: bounds.minY)
                        .rotated(by: .pi / 2)
                )
        case .leading:
            return topAnchoredPath(in: CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width))
                .applying(
                    CGAffineTransform(translationX: bounds.minX, y: bounds.maxY)
                        .rotated(by: -.pi / 2)
                )
        }
    }

    /// The shape with its flared side along the top of `rect`.
    ///
    /// Each corner is a quadratic curve whose control point sits where the two
    /// edges it joins would have met. For the flared pair that puts the control
    /// point *inside* the corner being cut away, which is precisely what turns
    /// the fillet concave — the same construction, the same tangents, the bulge
    /// the other way round.
    private func topAnchoredPath(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let f = max(0, min(flare, width / 2, height))
        let r = max(0, min(innerRadius, height - f, (width - 2 * f) / 2))

        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        path.addLine(to: CGPoint(x: f, y: height - r))
        path.addQuadCurve(to: CGPoint(x: f + r, y: height), control: CGPoint(x: f, y: height))
        path.addLine(to: CGPoint(x: width - f - r, y: height))
        path.addQuadCurve(to: CGPoint(x: width - f, y: height - r), control: CGPoint(x: width - f, y: height))
        path.addLine(to: CGPoint(x: width - f, y: f))
        path.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: width - f, y: 0))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The radius the HUD uses wherever it meets the display's frame.
///
/// Matched to the cutout's own corners, because that is the only rounding on
/// this machine the eye already knows. Every dock borrows it, so the notch and
/// the four edge docks are visibly the same object parked in different places.
enum HUDBezel {
    static let cornerRadius: CGFloat = 10
}

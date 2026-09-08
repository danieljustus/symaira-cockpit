import SwiftUI
import SymTuneCore
import SymairaTheme

/// The whole HUD, drawn on a stage that covers the display.
///
/// The view is handed the *display's* geometry and works out where the HUD goes
/// itself, rather than being sized to fit a window that was moved for it. That
/// inversion is the point: because position and size are ordinary SwiftUI
/// values, moving between docks, expanding and being dragged are all one
/// animatable change instead of three mechanisms.
///
/// Two shapes live here, and both are black on purpose. In the cutout the HUD
/// is horizontal and square-topped so it fuses with the bezel — that is
/// ``NotchHUDView``, kept exactly as it was. On a screen edge it is a thin
/// vertical sliver, flush with the display's frame and rounded only on the
/// inward side, that unfolds into a card when the pointer reaches it.
///
/// Neither is decoration around a window. Both are pretending to be part of the
/// machine, which is the whole reason they work.
@MainActor
struct HUDDockView: View {
    let model: TuneViewModel
    @ObservedObject var preferences: PreferencesManager

    /// The display the stage covers, in global screen coordinates.
    let metrics: NotchScreenMetrics
    let dock: HUDDock
    let isExpanded: Bool

    let notchWidth: CGFloat
    let shoulderWidth: CGFloat
    let menuBarHeight: CGFloat

    let openPanel: () -> Void
    let openCockpit: () -> Void
    let openCockpitTitle: String

    /// Both report a point in **global screen coordinates**, so the controller
    /// can hand it straight to `HUDDockLayout.nearestDock(to:on:)`.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    /// Where the drag has got to, relative to where it started. Reset by
    /// SwiftUI the instant the gesture ends, which is what makes the HUD spring
    /// back to its dock rather than sticking where it was dropped.
    @GestureState private var dragTranslation: CGSize = .zero

    private static let stageSpace = "symaira.hud.stage"

    /// The single spring every movement uses.
    ///
    /// One curve for expanding, docking and dropping, because the HUD should
    /// feel like one object with one weight. Slightly underdamped, so it
    /// settles with the small overshoot that reads as physical rather than
    /// mechanical.
    private var motion: Animation {
        .spring(response: 0.42, dampingFraction: 0.78)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Not hit-testable: the stage covers the display, and anything
            // clickable out here would swallow clicks meant for the desktop.
            Color.clear.allowsHitTesting(false)

            hud
                .frame(width: target.width, height: target.height)
                .position(x: target.midX, y: target.midY)
                .offset(dragTranslation)
                .animation(motion, value: dock)
                .animation(motion, value: isExpanded)
        }
        .frame(width: metrics.frame.width, height: metrics.frame.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.stageSpace))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Symaira HUD")
    }

    // MARK: - Geometry

    /// The HUD's frame in stage coordinates: top-left origin, because that is
    /// what SwiftUI lays out in, while `HUDDockLayout` answers in the
    /// bottom-left global space `NSScreen` uses.
    private var target: CGRect {
        let global = (isExpanded
            ? HUDDockLayout.expandedFrame(dock, on: metrics)
            : HUDDockLayout.collapsedFrame(dock, on: metrics))
            ?? .zero
        return CGRect(
            x: global.minX - metrics.frame.minX,
            y: metrics.frame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
    }

    /// Stage coordinates back to the global screen space the controller and
    /// `HUDDockLayout` both speak.
    private func globalPoint(_ stagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: metrics.frame.minX + stagePoint.x,
            y: metrics.frame.maxY - stagePoint.y
        )
    }

    // MARK: - The HUD

    @ViewBuilder
    private var hud: some View {
        Group {
            if dock == .notch {
                NotchHUDView(
                    model: model,
                    preferences: preferences,
                    notchWidth: notchWidth,
                    shoulderWidth: shoulderWidth,
                    menuBarHeight: menuBarHeight,
                    isExpanded: isExpanded,
                    openPanel: openPanel,
                    openCockpit: openCockpit,
                    openCockpitTitle: openCockpitTitle
                )
            } else {
                edge
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // A drag has to be able to start anywhere on the HUD, so there is no
        // separate handle to aim at — but that means the pointer must say what
        // the whole surface is for.
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private var dragGesture: some Gesture {
        // A few points of slack, so a click on a button in the expanded card is
        // still a click and not a one-pixel drag that dismisses it.
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.stageSpace))
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                onDragChanged(globalPoint(value.location))
            }
            .onEnded { value in
                onDragEnded(globalPoint(value.location))
            }
    }

    // MARK: - Edge dock

    /// The edge HUD: a black sliver flush with the display's frame, which
    /// unfolds inward into a card.
    ///
    /// It is drawn the way the notch dock is drawn, and for the same reason.
    /// The notch HUD has to be black because it is pretending to be the camera
    /// cutout; the edge HUD has to be black because it is pretending to be the
    /// bezel. In both cases the illusion dies the moment the fill is anything a
    /// display frame could not be — a glass pill parked near the edge reads as
    /// a small window, not as part of the machine.
    ///
    /// Which is why an earlier pass at this using Liquid Glass was wrong: the
    /// material is beautiful and it is the wrong material for something whose
    /// whole job is to disappear into a black border.
    private var edge: some View {
        ZStack {
            Color.black
            if isExpanded {
                edgeCard
            }
        }
        .clipShape(edgeShape)
        .overlay(
            // Only the inward edges are drawn. A line along the screen edge
            // would trace the outline of a window, which is the one thing this
            // must never look like.
            edgeShape.strokeBorder(
                isExpanded ? SymairaTheme.borderGlass : Color.clear,
                lineWidth: 1
            )
        )
    }

    /// Rounded on the inward side only, square where it meets the screen edge.
    ///
    /// The square side is what makes it stick: a shape rounded on all four
    /// corners has a visible gap of desktop between it and the bezel, however
    /// flush its frame is.
    private var edgeShape: UnevenRoundedRectangle {
        let radius: CGFloat = isExpanded ? SymairaRadius.panel : 5
        return dock.isRightEdge
            ? UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            : UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius
            )
    }

    /// Expanded: every monitored metric, not just the ones that fit on the
    /// pill — the point of expanding is to see what did not.
    private var edgeCard: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            ForEach(model.metricRows) { row in
                HStack(spacing: SymairaSpacing.small) {
                    Image(systemName: row.id.statusItemSymbol)
                        .symairaText(.caption)
                        .frame(width: 16)
                        .foregroundStyle(SymairaTheme.goldPrimary)
                    Text(row.title)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textSecondary)
                    Spacer(minLength: SymairaSpacing.small)
                    Text(row.current)
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTheme.textPrimary)
                }
            }
            if model.metricRows.isEmpty {
                Text("No metric is being monitored")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }

            Divider().overlay(SymairaTheme.borderGlass)

            HStack(spacing: SymairaSpacing.small) {
                actionButton("Panel", symbol: "slider.horizontal.3", action: openPanel)
                actionButton(
                    openCockpitTitle,
                    symbol: "gauge.with.dots.needle.bottom.50percent",
                    action: openCockpit
                )
                Spacer(minLength: 0)
            }
        }
        .padding(SymairaSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .symairaText(.caption)
            .foregroundStyle(SymairaTheme.textPrimary)
            .padding(.horizontal, SymairaSpacing.small)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: SymairaRadius.control)
                    .fill(SymairaTheme.bgCardHover.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.control)
                    .strokeBorder(SymairaTheme.borderGlass, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

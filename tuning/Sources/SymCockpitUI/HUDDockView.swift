import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The whole HUD, drawn on a stage that covers the display.
///
/// The view is handed the *display's* geometry and works out where the HUD goes
/// itself, rather than being sized to fit a window that was moved for it. That
/// inversion is the point: because position and size are ordinary SwiftUI
/// values, moving between docks, opening and being dragged are all one
/// animatable change instead of three mechanisms.
///
/// Both resting shapes are black on purpose. Expanded cards use the shared
/// appearance-aware surface, typography and actions. In the cutout the HUD
/// is horizontal and square-topped so it fuses with the bezel — that is
/// ``NotchHUDView``. On a screen edge it is a thin vertical sliver, flush with
/// the display's frame and rounded only on the inward side, that swells and
/// then unfolds into a card.
///
/// Neither is decoration around a window. Both are pretending to be part of the
/// machine, which is the whole reason they work.
@MainActor
struct HUDDockView: View {
    let resolveItems: ([HUDItemKind]) -> [HUDItemValue]
    let itemLayout: HUDItemLayout
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// The display the stage covers, in global screen coordinates.
    let metrics: NotchScreenMetrics
    let dock: HUDDock
    let presentation: HUDPresentation

    let notchWidth: CGFloat
    let menuBarHeight: CGFloat

    let openPanel: () -> Void
    let openCockpit: () -> Void
    let openCockpitTitle: String
    /// A click on the HUD's own surface — not on a control inside the card.
    let onToggle: () -> Void

    /// Both report a point in **global screen coordinates**, so the controller
    /// can hand it straight to `HUDDockLayout.nearestDock(to:on:)`.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    /// What the drag is doing to the HUD's position and shape.
    ///
    /// Reset by SwiftUI the instant the gesture ends, which — together with the
    /// spring below — is what makes the HUD snap back to its dock rather than
    /// stick where it was dropped. See ``HUDDragPhysics``.
    @GestureState private var drag: HUDDragState = .resting

    private static let stageSpace = "symaira.hud.stage"

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Not hit-testable: the stage covers the display, and anything
            // clickable out here would swallow clicks meant for the desktop.
            Color.clear.allowsHitTesting(false)

            hud
                .frame(width: target.width, height: target.height)
                // Applied before `.position`, and anchored at the edge the HUD
                // is parked against, so the stretch peels the shape away from
                // the bezel instead of scaling it about its own middle.
                .scaleEffect(drag.stretch, anchor: stretchAnchor)
                .position(x: target.midX, y: target.midY)
                .offset(drag.offset)
                .animation(HUDMotion.dock, value: dock)
                .animation(presentationMotion, value: presentation)
                // Two curves for one value: while the gesture is live the HUD
                // tracks the pointer, and the moment it is released the same
                // property springs home. Choosing the animation from
                // `drag.isActive` is what lets one modifier do both.
                .animation(drag.isActive ? HUDMotion.track : HUDMotion.release, value: drag.offset)
                .animation(drag.isActive ? HUDMotion.track : HUDMotion.release, value: drag.stretch)
        }
        .frame(width: metrics.frame.width, height: metrics.frame.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.stageSpace))
        .transaction {
            if reduceMotion {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Symaira HUD")
    }

    // MARK: - Geometry

    /// The HUD's frame in stage coordinates: top-left origin, because that is
    /// what SwiftUI lays out in, while `HUDDockLayout` answers in the
    /// bottom-left global space `NSScreen` uses.
    private var target: CGRect {
        let global = HUDDockLayout.frame(
            dock,
            on: metrics,
            presentation: presentation,
            contentHeight: HUDDockLayout.expandedContentHeight(for: itemLayout, dock: dock)
        ) ?? .zero
        return CGRect(
            x: global.minX - metrics.frame.minX,
            y: metrics.frame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
    }

    /// Shoulder width for the presentation being drawn. Only the notch dock has
    /// shoulders; the edge docks answer zero and never ask.
    private var shoulderWidth: CGFloat {
        let width = switch presentation {
        case .collapsed: NotchLayout.shoulderWidth(metrics)
        case .peek, .expanded: NotchLayout.peekShoulderWidth(metrics)
        }
        // Expanded still shows peek items; do not squeeze them back into the
        // collapsed shoulder. The current card/camera geometry is a hard cap.
        return min(width ?? 0, max(0, (target.width - notchWidth) / 2))
    }

    /// The edge the HUD is attached to, and therefore the point a stretch must
    /// hold still.
    private var stretchAnchor: UnitPoint {
        switch dock {
        case .notch: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Opening the card is a longer gesture than peeking, and using one curve
    /// for both made the peek feel slow.
    private var presentationMotion: Animation {
        presentation == .expanded ? HUDMotion.expand : HUDMotion.peek
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
                    resolveItems: resolveItems,
                    itemLayout: itemLayout,
                    notchWidth: notchWidth,
                    shoulderWidth: shoulderWidth,
                    menuBarHeight: menuBarHeight,
                    presentation: presentation,
                    openPanel: openPanel,
                    openCockpit: openCockpit,
                    openCockpitTitle: openCockpitTitle,
                    onToggle: onToggle
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
        // still a click and not a one-pixel drag that dismisses it. It is also
        // what keeps the tap gesture on the strip usable: below this distance
        // the drag never starts, so the click is unambiguous.
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.stageSpace))
            .updating($drag) { value, state, _ in
                state = HUDDragPhysics.resolve(translation: value.translation, dock: dock)
            }
            .onChanged { value in
                onDragChanged(globalPoint(value.location))
            }
            .onEnded { value in
                onDragEnded(globalPoint(value.location))
            }
    }

    // MARK: - Edge dock

    /// The edge HUD: a black sliver flush with the display's frame, which swells
    /// under the pointer and unfolds inward into a card.
    ///
    /// Parked and peeking remain black like the bezel. The expanded card uses
    /// the same quiet content surface as Cockpit, with no animated background
    /// competing with these tightly packed readings.
    private var edge: some View {
        Group {
            switch presentation {
            case .collapsed:
                // Nothing fits in seven points, and the sliver's job parked is
                // to be mistaken for the bezel anyway.
                Color.clear
            case .peek:
                edgePeek
            case .expanded:
                edgeCard
            }
        }
        .background {
            (presentation == .expanded ? SymairaTheme.surfaceOpaque(for: colorScheme) : Color.black)
                .clipShape(edgeShape)
                .overlay(
                    // Only the inward edges are drawn. A line along the screen
                    // edge would trace the outline of a window, which is the
                    // one thing this must never look like.
                    edgeShape.strokeBorder(
                        presentation == .expanded ? SymairaTheme.line(for: colorScheme) : Color.clear,
                        lineWidth: contrast == .increased ? 2 : 1
                    )
                )
                // Room for the flare, taken from outside the frame rather than
                // out of the card's own height.
                .padding(.vertical, -HUDBezel.cornerRadius)
        }
        // The sliver is the click target, in every state — the same role the
        // strip plays for the notch dock.
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// Flared into the display's frame on the outward side, rounded on the
    /// inward one.
    ///
    /// Both ends of the side that lies along the screen edge run out into the
    /// frame instead of stopping at a right angle — the same treatment the
    /// notch dock gets at the top of the display, for the same reason. See
    /// ``HUDBezelShape``.
    private var edgeShape: HUDBezelShape {
        let innerRadius: CGFloat = switch presentation {
        case .collapsed: 5
        case .peek: SymairaRadius.control
        case .expanded: SymairaRadius.panel
        }
        return HUDBezelShape(
            anchor: dock.isRightEdge ? .trailing : .leading,
            flare: HUDBezel.cornerRadius,
            innerRadius: innerRadius
        )
    }

    /// Peeking: the items the user put at the hover stage, stacked in a column
    /// narrow enough that the sliver still reads as part of the frame.
    ///
    /// Both sides' items appear here. The left/right split is about the notch's
    /// two shoulders and the card's two columns; an edge dock has one narrow
    /// strip, and dropping half the user's choices on the floor because they
    /// picked the "wrong" side would be a trap.
    private var edgePeek: some View {
        VStack(spacing: 6) {
            ForEach(resolveItems(itemLayout.items(at: .peek))) { item in
                HUDCompactItem(item: item)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(HUDMotion.peek, value: presentation)
    }

    /// Expanded: every item the user placed, plus the actions.
    private var edgeCard: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            let left = resolveItems(itemLayout.items(on: .left, at: .expanded))
            let right = resolveItems(itemLayout.items(on: .right, at: .expanded))

            if left.isEmpty && right.isEmpty {
                HUDEmptyState(hasEnabledItems: itemLayout.hasItems(at: .expanded))
            } else {
                // One column, not two: the edge card is 288 points wide, and
                // splitting that leaves neither side room for a label and a
                // number on one line.
                ScrollView {
                    VStack(spacing: SymairaSpacing.xSmall) {
                        ForEach(left + right) { item in
                            HUDCardRow(item: item)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider().overlay(SymairaTheme.line(for: colorScheme))
            HUDCardActions(openPanel: openPanel, openCockpit: openCockpit, openCockpitTitle: openCockpitTitle)
        }
        .padding(SymairaSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }

}

import SwiftUI
import SymTuneCore
import SymairaTheme

/// The notch HUD's content (issues #224, #255).
///
/// Three states in one view, because they share the top strip: parked is the
/// strip alone, peeking is the same strip with wider shoulders and a few points
/// of drop, and expanded keeps both and hangs a card below. Drawing them as one
/// view is what makes each step look like the strip growing rather than a
/// second window appearing.
///
/// What goes on the shoulders is no longer "the first two menu-bar metrics".
/// It is whatever the user placed there — see ``HUDItemLayout`` — which is what
/// makes the peek worth having: the middle state can hold the readouts that
/// were not important enough to keep on screen permanently, without being the
/// whole card.
///
/// Everything here is read off the same ``TuneViewModel`` the status item and
/// the popover use. There is no second polling pipeline.
@MainActor
struct NotchHUDView: View {
    let model: TuneViewModel
    let itemLayout: HUDItemLayout

    /// Width of the camera cutout — the dead zone between the shoulders.
    let notchWidth: CGFloat
    /// Width of one shoulder at the presentation being drawn.
    let shoulderWidth: CGFloat
    /// Height of the menu bar strip the collapsed HUD lives in.
    let menuBarHeight: CGFloat

    let presentation: HUDPresentation
    let openPanel: () -> Void
    let openCockpit: () -> Void
    let openCockpitTitle: String
    /// A click on the strip: opens the card, or closes it again.
    let onToggle: () -> Void

    private var isExpanded: Bool { presentation == .expanded }

    var body: some View {
        VStack(spacing: 0) {
            strip
            if isExpanded {
                card
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            background
                .clipShape(shape)
                .overlay(
                    // Only the bottom edge is drawn: the top edge is the
                    // physical bezel, and a line there would give the illusion
                    // away.
                    shape.strokeBorder(
                        isExpanded ? SymairaTheme.borderGlass : Color.clear,
                        lineWidth: 1
                    )
                )
                // The flare lives outside the frame the readouts were laid out
                // in. Negative padding is what buys it that room without
                // taking a single point away from the shoulders.
                .padding(.horizontal, -HUDBezel.cornerRadius)
        }
        .animation(HUDMotion.expand, value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch HUD")
    }

    // MARK: - Shape and fill

    /// Flared into the bezel at the top, rounded at the bottom so it reads as
    /// one shape with the cutout above it.
    ///
    /// The top corners are concave — see ``HUDBezelShape``. Square ones there
    /// were what made the strip look like a black rectangle someone had pushed
    /// against the top of the screen; convex ones would have been worse, since
    /// they close the outline off entirely.
    ///
    /// The bottom radius grows with the presentation. That is the peek's whole
    /// silhouette: parked, the corners match the cutout's own; peeking, they
    /// round further as the shape drops, which is what sells "it swelled"
    /// instead of "it was replaced".
    private var shape: HUDBezelShape {
        let innerRadius: CGFloat = switch presentation {
        case .collapsed: HUDBezel.cornerRadius
        case .peek: HUDBezel.cornerRadius + NotchLayout.peekDrop
        case .expanded: SymairaRadius.panel
        }
        return HUDBezelShape(
            anchor: .top,
            flare: HUDBezel.cornerRadius,
            innerRadius: innerRadius
        )
    }

    /// Collapsed, the fill has to be the cutout's own black or the seam shows.
    /// Expanded, the card below the menu bar strip may be the usual glass.
    private var background: some View {
        ZStack {
            Color.black
            if isExpanded {
                SymairaTheme.bgCard.opacity(0.55)
                    .padding(.top, menuBarHeight)
            }
        }
    }

    // MARK: - Items

    private func items(on side: HUDItemSide, at stage: HUDPresentation) -> [HUDItemValue] {
        HUDItemResolver.values(
            for: itemLayout.items(on: side, at: stage),
            model: model
        )
    }

    /// What the *shoulders* show, which is never more than the peek's worth.
    ///
    /// A shoulder is 64 points parked and about 116 peeking, and that is a hard
    /// budget — it is carved out of the menu titles and the status items either
    /// side of the cutout. Letting the expanded stage's items onto it would put
    /// `Sleep allowed` in a space that fits `40 %`, and the strip would render
    /// a clipped fragment of a word.
    ///
    /// So the strip stops at ``HUDPresentation/peek`` and the card takes it
    /// from there. The two surfaces are not the same list at two sizes; the
    /// shoulders are the glanceable one, and opening the HUD is how the rest
    /// arrives.
    private var stripStage: HUDPresentation {
        min(presentation, .peek)
    }

    // MARK: - The strip

    /// The two shoulders, with the cutout's width held open between them.
    ///
    /// The strip is also the click target: it is present in all three states,
    /// which makes it the one part of the HUD that can both open the card and
    /// close it again. Putting the gesture here rather than on the whole HUD is
    /// what keeps a click on a button inside the card from counting as a click
    /// on the HUD.
    private var strip: some View {
        HStack(spacing: 0) {
            shoulder(items(on: .left, at: stripStage), alignment: .trailing)
            Color.clear.frame(width: notchWidth)
            shoulder(items(on: .right, at: stripStage), alignment: .leading)
        }
        .frame(height: menuBarHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Closes the HUD" : "Opens the HUD")
    }

    private func shoulder(
        _ items: [HUDItemValue],
        alignment: Alignment
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                HUDCompactItem(item: item)
                    // Each readout arrives from the cutout's direction rather
                    // than fading in place, so a peek looks like the shoulder
                    // sliding content out from behind the camera housing.
                    .transition(
                        .opacity.combined(
                            with: .move(edge: alignment == .trailing ? .trailing : .leading)
                        )
                    )
            }
        }
        // Padding inside the fixed width, not around it: the shoulder's width
        // is what `NotchLayout` budgeted from the menu bar strip, and padding
        // applied outside the frame would quietly spend 8pt more per side.
        .padding(.horizontal, 4)
        .frame(width: shoulderWidth, alignment: alignment)
        // Clipped, because the shoulder's width is a promise to the menu titles
        // underneath: an item mid-transition must not spill past it.
        .clipped()
        .animation(HUDMotion.peek, value: stripStage)
    }

    // MARK: - Expanded card

    private var card: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            let left = items(on: .left, at: .expanded)
            let right = items(on: .right, at: .expanded)

            if left.isEmpty && right.isEmpty {
                HUDEmptyState(hasEnabledItems: itemLayout.hasItems(at: .expanded))
            } else {
                HUDCardColumns(left: left, right: right)
            }

            Divider().overlay(SymairaTheme.borderGlass)
            actions
        }
        .padding(SymairaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var actions: some View {
        HStack(spacing: SymairaSpacing.small) {
            actionButton("Panel", symbol: "slider.horizontal.3", action: openPanel)
            actionButton(openCockpitTitle, symbol: "gauge.with.dots.needle.bottom.50percent", action: openCockpit)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
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

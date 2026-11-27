import SwiftUI
import SymairaTheme
import SymCockpitCore

/// One item as it appears on a shoulder or a sliver: icon, number, nothing else.
///
/// Shared by every dock, because "compact" means the same thing in the notch's
/// narrow shoulder and on an edge dock's peeking sliver, and having written
/// it twice once is enough.
@MainActor
struct HUDCompactItem: View, Equatable {
    let item: HUDItemValue
    /// Squeeze into whatever width the parent offers instead of taking the
    /// natural one, and show ``MetricFormatting/compactReadout(_:)`` rather than
    /// the long text.
    ///
    /// The parked notch shoulder (``NotchLayout/preferredShoulder``) sets this:
    /// its width is a budget, so a readout that does not fit has to give — a
    /// shorter string first, then a smaller one, never a wider shoulder and
    /// never a clipped digit. The notch strip sets it in every presentation:
    /// the peeking shoulder is wider, but two long readouts side by side still
    /// overran it and were clipped at the outer edges. Without it the item
    /// keeps its natural size, which is what the edge docks have always had.
    var fitsWidth = false

    /// Lighter and a step smaller than the shared caption: the strip sits next
    /// to the menu bar's own titles, and at caption weight the readouts read
    /// heavier than the system text around them.
    static let valueFont = SymairaFont.font(size: 10.5, weight: 400, relativeTo: .caption2)

    private var text: String {
        fitsWidth ? MetricFormatting.compactReadout(item.value) : item.value
    }

    var body: some View {
        HStack(spacing: 3) {
            SymairaIconView(symbol: item.symbolName, size: 12)
                .foregroundStyle(item.isActive
                    ? SymairaTheme.accent(for: .dark) : SymairaTheme.foregroundSecondary(for: .dark))
            Text(text)
                .font(Self.valueFont.monospacedDigit())
                .foregroundStyle(SymairaTheme.foregroundPrimary(for: .dark))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // No numeric content transition here. The shoulders are always on
        // screen when the HUD is the readout surface, so every metrics sample
        // would interpolate two glyph bitmaps through a software blur in a
        // full-display CGDrawingLayer (issue #418). A glanceable readout can
        // swap its digits outright; the rolling animation is reserved for the
        // card the user opened. Equatable above also skips the body entirely
        // when the formatted value did not change.
        .fixedSize(horizontal: !fitsWidth, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value)")
    }
}

/// One item in a peeking edge dock: the icon centred above the value.
///
/// The edge sliver is a narrow column, and an icon beside a long value did not
/// fit it — `397.4 GB` ran into the screen edge and was clipped. Stacked, the
/// value gets the sliver's whole width, both sides of the column keep the same
/// margin, and the short form (``MetricFormatting/compactReadout(_:)``) plus
/// scaling make sure nothing is cut off. The accessibility label keeps the
/// full text.
@MainActor
struct HUDStackedItem: View, Equatable {
    let item: HUDItemValue

    private var text: String { MetricFormatting.compactReadout(item.value) }

    var body: some View {
        VStack(spacing: 2) {
            SymairaIconView(symbol: item.symbolName, size: 11)
                .foregroundStyle(item.isActive
                    ? SymairaTheme.accent(for: .dark) : SymairaTheme.foregroundSecondary(for: .dark))
            Text(text)
                .font(HUDCompactItem.valueFont.monospacedDigit())
                .foregroundStyle(SymairaTheme.foregroundPrimary(for: .dark))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // As on the notch shoulders, the peek is an always-present software
        // surface: no interpolated glyph bitmaps and no blur per sample.
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value)")
    }
}

/// One item as a row in the expanded card: icon, name, value pushed right.
@MainActor
struct HUDCardRow: View {
    let item: HUDItemValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SymairaSpacing.xSmall) {
            SymairaIconView(symbol: item.symbolName, size: 16)
                .frame(width: 16)
                .foregroundStyle(item.isActive
                    ? SymairaTheme.selected(for: colorScheme) : SymairaTheme.foregroundSecondary(for: colorScheme))
            Text(item.title)
                .symairaText(.callout)
                .lineLimit(1)
            Spacer(minLength: SymairaSpacing.xSmall)
            Text(item.value)
                .font(SymairaTypography.label.monospacedDigit())
                .foregroundStyle(item.isActive
                    ? SymairaTheme.selected(for: colorScheme) : SymairaTheme.foregroundPrimary(for: colorScheme))
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : HUDMotion.value, value: item.value)
        }
        .frame(height: HUDDockLayout.expandedRowHeight - SymairaSpacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value)")
    }
}

/// Both docks use AppKit actions, not a second miniature button theme.
@MainActor
struct HUDCardActions: View {
    let openPanel: () -> Void
    let openCockpit: () -> Void
    let openCockpitTitle: String

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            Button(action: openPanel) {
                Label("Panel", symairaIcon: .tune, iconSize: 16)
            }
            .symairaButtonStyle(.secondary)
            .accessibilityIdentifier("hud-open-panel")
            Button(action: openCockpit) {
                Label(openCockpitTitle, symairaIcon: .productCockpit, iconSize: 16)
            }
            .symairaButtonStyle(.primary)
            .accessibilityIdentifier("hud-open-cockpit")
            Spacer(minLength: 0)
        }
    }
}

/// The card's two columns — the same left/right split the shoulders use, kept
/// when the HUD opens so an item does not change sides on the way there.
///
/// Collapses to one column when only one side has anything in it, rather than
/// leaving half the card empty next to a list of four.
@MainActor
struct HUDCardColumns: View {
    let left: [HUDItemValue]
    let right: [HUDItemValue]

    var body: some View {
        HStack(alignment: .top, spacing: SymairaSpacing.large) {
            if !left.isEmpty {
                column(left)
            }
            if !right.isEmpty {
                column(right)
            }
        }
    }

    private func column(_ items: [HUDItemValue]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                HUDCardRow(item: item)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the card says when the user has switched everything off, or when
/// nothing they chose has data yet.
///
/// Worth a sentence rather than an empty card: with the placement settings this
/// state is now reachable on purpose, and a blank card is indistinguishable
/// from a broken one.
@MainActor
struct HUDEmptyState: View {
    let hasEnabledItems: Bool

    var body: some View {
        Text(hasEnabledItems
            ? "Nothing to report yet"
            : "Choose readouts under Menu bar › HUD content")
            .symairaText(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

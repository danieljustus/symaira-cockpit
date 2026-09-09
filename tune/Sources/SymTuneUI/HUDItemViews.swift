import SwiftUI
import SymairaTheme
import SymTuneCore

/// One item as it appears on a shoulder or a sliver: icon, number, nothing else.
///
/// Shared by every dock, because "compact" means the same thing in the notch's
/// 64-point shoulder and on an edge dock's peeking sliver, and having written
/// it twice once is enough.
@MainActor
struct HUDCompactItem: View {
    let item: HUDItemValue

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: item.symbolName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(SymairaTheme.goldPrimary)
            Text(item.value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // The digits roll rather than cut, which is most of what makes
                // a live readout read as live.
                .contentTransition(.numericText())
                .animation(HUDMotion.value, value: item.value)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value)")
    }
}

/// One item as a row in the expanded card: icon, name, value pushed right.
@MainActor
struct HUDCardRow: View {
    let item: HUDItemValue

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            Image(systemName: item.symbolName)
                .symairaText(.caption)
                .frame(width: 16)
                .foregroundStyle(SymairaTheme.goldPrimary)
            Text(item.title)
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: SymairaSpacing.small)
            Text(item.value)
                .symairaText(.monoSmall)
                .foregroundStyle(item.isActive ? SymairaTheme.goldPrimary : SymairaTheme.textPrimary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(HUDMotion.value, value: item.value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value)")
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
            : "No readouts chosen — pick some under Menu bar › HUD content")
            .symairaText(.caption)
            .foregroundStyle(SymairaTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

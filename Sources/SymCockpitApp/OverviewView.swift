import SwiftUI
import SymairaTheme

/// The tune landing section and shortcut into the detailed panel.
///
/// It deliberately shows no Tune metrics — those live in the menu bar, which is
/// always visible, and duplicating them here would mean a second polling
/// pipeline for a number the user already has.
@MainActor
struct OverviewView: View {
    let openSection: (CockpitSection) -> Void

    var body: some View {
        CockpitSectionScroll(
            title: "Symaira Cockpit",
            status: nil
        ) {
            Text("Your Mac's thermals, power and display controls — the same data `symcockpit tune` prints, in one window. Live metrics stay in the menu bar.")
                .font(SymairaTypography.callout)
                .foregroundStyle(SymairaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            CockpitNavCard(section: .tune, action: { openSection(.tune) }) {
                Text("Brightness, colour warmth, keep-awake, fans and the system readout.")
                    .font(SymairaTypography.callout)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }

            Text("⌘1–⌘2 switch sections · right-click the menu-bar icon for this window, preferences and quit.")
                .font(SymairaTypography.caption)
                .foregroundStyle(SymairaTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// An overview card that navigates. It looks like a card until the pointer is
/// over it, then it lights up and shows a chevron — without that, a clickable
/// card is indistinguishable from a static one.
private struct CockpitNavCard<Content: View>: View {
    let section: CockpitSection
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SymairaTheme.goldPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title.uppercased())
                            .font(SymairaTypography.label)
                            .kerning(0.6)
                            .foregroundStyle(SymairaTheme.goldPrimary)
                        Text(section.blurb)
                            .font(SymairaTypography.caption)
                            .foregroundStyle(SymairaTheme.textMuted)
                    }
                    Spacer(minLength: SymairaSpacing.small)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SymairaTheme.textMuted)
                        .opacity(isHovered ? 1 : 0.35)
                }
                content
            }
            .padding(SymairaSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cockpitCardSurface(hovered: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(SymairaTheme.transitionFast) { isHovered = hovering }
        }
        .help("Open \(section.title)")
    }
}

import SwiftUI
import SymairaTheme
import SymTuneUI

/// The Tune section: the menu-bar panel's cards, in the cockpit's own frame.
///
/// The panel is embedded rather than reimplemented — same controller, same
/// `TuneViewModel`, same cards, so the window and the menu bar can never
/// disagree. What the cockpit supplies is the chrome: its section header, its
/// column width, its scrolling. `TunePanelChrome.embedded` drops the popover's
/// fixed 320pt frame, its "SYMAIRA TUNE" header and its footer, which would
/// otherwise read as a popover pasted into a window.
@MainActor
struct TuneSectionView: View {
    let statusBar: StatusBarController
    let openPreferences: () -> Void

    var body: some View {
        CockpitSectionScroll(
            title: "Tune",
            command: CockpitSection.tune.command,
            status: "live"
        ) {
            Text("Thermals, power and display — the same live model the menu bar reads.")
                .font(SymairaTypography.callout)
                .foregroundStyle(SymairaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            statusBar.tunePanel(chrome: .embedded)

            Button {
                openPreferences()
            } label: {
                Label("Metrics, AI usage and update settings", systemImage: "gearshape")
                    .font(SymairaTypography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SymairaTheme.textMuted)
            .help("Open Tune preferences (⌘,)")
        }
    }
}

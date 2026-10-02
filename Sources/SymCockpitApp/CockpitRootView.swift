import SwiftUI
import SymairaTheme
import SymTuneUI

/// One tuning surface, backed by the menu bar's existing model and cards.
@MainActor
struct CockpitRootView: View {
    let statusBar: StatusBarController
    let openPreferences: () -> Void

    var body: some View {
        CockpitWorkspaceView(version: CockpitAppVersion.current, openPreferences: openPreferences) {
            statusBar.tunePanel(chrome: .embedded)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: openPreferences) {
                    Label("Preferences", systemImage: "gearshape")
                }
                .help("Open preferences (⌘,)")
            }
        }
    }
}

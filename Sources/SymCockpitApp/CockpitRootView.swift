import SwiftUI
import SymairaTheme
import SymCockpitUI

/// One tuning surface, backed by the menu bar's existing model and cards.
@MainActor
struct CockpitRootView: View {
    let statusBar: StatusBarController
    let openPreferences: () -> Void

    var body: some View {
        CockpitWorkspaceView(
            version: CockpitAppVersion.current, openPreferences: openPreferences,
            appearance: statusBar.appearancePreferences
        ) {
            statusBar.tunePanel(chrome: .embedded)
        }
    }
}

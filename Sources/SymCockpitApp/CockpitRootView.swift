import SwiftUI
import SymairaTheme
import SymTuneUI

/// One tuning surface, backed by the menu bar's existing model and cards.
@MainActor
struct CockpitRootView: View {
    let statusBar: StatusBarController
    let openPreferences: () -> Void

    var body: some View {
        ScrollView {
            statusBar.tunePanel(chrome: .embedded)
                .padding(SymairaSpacing.xLarge)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(SymairaTheme.bgDark)
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

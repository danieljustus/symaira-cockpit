import SwiftUI
import SymairaTheme
import SymCockpitUI

/// The cockpit window: the workspace shell and its pages, built by the status bar
/// controller from the models the menu-bar popover already runs.
@MainActor
struct CockpitRootView: View {
    let statusBar: StatusBarController
    let openPreferences: () -> Void
    let navigation: CockpitNavigation

    var body: some View {
        statusBar.cockpitWorkspace(
            version: CockpitAppVersion.current, openPreferences: openPreferences, navigation: navigation
        )
    }
}

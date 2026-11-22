import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Display, second in the sidebar.
// 2. Job: set how the screen looks and whether the Mac stays awake.
// 3. Data: the agent's `status`, `brightness.get` and `awake.status` topics; `profile.list` when the page opens.
// 4. States: loading (profiles, displays), empty (no profiles, no displays), error (a refused
//    write shows under its control; a failed profile list has Retry), unreachable (the shell's diagnosis).
// 5. Density: dashboard grid, 960 pt.
// 6. Platform: macOS workspace. Brightness keys use their existing preference.

@MainActor
struct DisplayPage: View {
    let context: CockpitPageContext

    private var model: TuneViewModel { context.model }

    var body: some View {
        SymairaPage(
            title: CockpitDestination.display.title, subtitle: CockpitDestination.display.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                DisplayControlsCard(
                    model: model, config: context.config,
                    brightnessKeys: context.brightnessKeyPreferences,
                    brightnessKeyController: context.brightnessKeyController
                )
                PairedCards {
                    KeepAwakeSection(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    ProfilesCard(model: context.profiles, isAgentReady: model.isAgentReady)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                DisplaysSection(model: model)
            }
        }
    }
}

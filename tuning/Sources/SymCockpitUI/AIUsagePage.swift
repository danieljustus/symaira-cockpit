import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: AI Usage.
// 2. Job: see how much of each AI provider's limits is used; Customize chooses the providers.
// 3. Data: the agent's `ai-usage` (network, slow), fetched while this page is on screen and
//    refreshed from the card's own Refresh button.
// 4. States: loading (first fetch), empty (no providers in the catalog; the card itself says when
//    none is chosen), error (a provider that failed shows its own message and keeps stale values),
//    unreachable (the shell's diagnosis).
// 5. Density: one wide card, 960 pt.
// 6. Platform: macOS workspace; the AI usage preferences keep their keys.

@MainActor
struct AIUsagePage: View {
    let context: CockpitPageContext

    private var model: AIUsageViewModel { context.aiUsageModel }

    var body: some View {
        SymairaPage(
            title: CockpitDestination.aiUsage.title, subtitle: CockpitDestination.aiUsage.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            if model.providers.isEmpty {
                SymairaPageEmpty(
                    icon: .ai, title: "No Providers",
                    message: "No AI provider is available to this build, so there is no usage to show."
                )
            } else if model.rows.isEmpty && model.isRefreshing {
                SymairaPageState<Int, EmptyView>(
                    state: .loading, loading: "Reading AI usage…", retry: {}, loaded: { _ in EmptyView() }
                )
            } else {
                AIUsageCardView(model: model)
            }
        }
        // The agent reads usage over the network, so it is fetched only while someone looks.
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
    }
}

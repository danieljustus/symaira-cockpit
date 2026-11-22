import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Processes: a placeholder until its page is built. Part 2 of wave 2D-3 replaces
/// this file and nothing else: the page gets the app's `AgentSession` and no other
/// object, and reads and acts only through it.
public struct ProcessesPage: View {
    private let session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.processes.title, subtitle: CockpitDestination.processes.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            SymairaEmptyState(
                icon: .cpu,
                title: "Not available yet",
                message: "Processes is not part of this window yet."
            )
            .frame(maxWidth: .infinity, minHeight: SymairaPageLayout.stateHeight)
            .accessibilityIdentifier("page-not-available")
        }
    }
}

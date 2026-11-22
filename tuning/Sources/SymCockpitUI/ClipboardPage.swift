import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Clipboard: a placeholder until its page is built. Part 2 of wave 2D-3 replaces
/// this file and nothing else: the page gets the app's `AgentSession` and no other
/// object, and reads and acts only through it.
public struct ClipboardPage: View {
    private let session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.clipboard.title, subtitle: CockpitDestination.clipboard.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            SymairaEmptyState(
                icon: .paste,
                title: "Not available yet",
                message: "Clipboard is not part of this window yet."
            )
            .frame(maxWidth: .infinity, minHeight: SymairaPageLayout.stateHeight)
            .accessibilityIdentifier("page-not-available")
        }
    }
}

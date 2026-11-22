import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Bluetooth & Input: a placeholder until its page is built. Part 2 of wave 2D-3 replaces
/// this file and nothing else: the page gets the app's `AgentSession` and no other
/// object, and reads and acts only through it.
public struct BluetoothInputPage: View {
    private let session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.bluetoothInput.title, subtitle: CockpitDestination.bluetoothInput.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            SymairaEmptyState(
                icon: .keyboard,
                title: "Not available yet",
                message: "Bluetooth & Input is not part of this window yet."
            )
            .accessibilityIdentifier("page-not-available")
        }
    }
}

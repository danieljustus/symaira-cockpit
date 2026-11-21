import SwiftUI
import SymairaTheme
import SymCockpitCore

/// Shown instead of readings while the Cockpit agent cannot serve: it did not
/// start, speaks another protocol version, refused its parent or died. It says
/// what the agent client reported and offers the one manual way out. There is
/// no automatic restart, so a crash loop cannot hide.
struct AgentDiagnosisCard: View {
    let diagnosis: AgentDiagnosis
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            SymairaNotice(title: diagnosis.title, message: diagnosis.detail, tone: .critical)
                .accessibilityIdentifier("agent-diagnosis")
            Button("Restart agent", action: restart)
                .symairaButtonStyle(.secondary)
        }
    }
}

import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Battery charge limit. Setting or removing one is a risky command: the agent only
/// plans it and the shared plan confirmation applies it after the user said so.
/// The agent cannot read the limit that is in force, so the card says only what this
/// app confirmed itself since it started.
@MainActor
struct ChargeLimitCard: View {
    let model: TuneViewModel
    @State private var percent = 80

    private static let choices = [60, 70, 80, 85, 90, 95]

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Label("Charge Limit", symairaIcon: .battery, iconSize: 16)
                .symairaText(.subheading)
                .foregroundStyle(SymairaTokens.ink2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var content: some View {
        if let battery = model.battery, !battery.present {
            note("No battery detected. This Mac has nothing to limit.")
        } else if let battery = model.battery, !battery.chargeLimitSupported {
            note("Not supported on this Mac. Its power controller offers no charge limit.")
        } else {
            controls
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("Stopping at a lower charge is gentler on the battery when the Mac stays plugged in.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SymairaSpacing.small) {
                SymairaFilterMenu(
                    "Charge limit", selection: $percent,
                    options: Self.choices.map { ($0, "\($0) %") }
                )
                Button("Set Limit") { Task { await model.requestChargeLimit(percent) } }
                    .symairaButtonStyle(.secondary)
                Button("Remove Limit") { Task { await model.requestChargeLimit(nil) } }
                    .symairaButtonStyle(.secondary)
            }
            .disabled(!model.isAgentReady || model.chargeBusy || (model.pendingChargeChange?.isOpen ?? false))
            if let pending = model.pendingChargeChange {
                PlanConfirmationView(
                    model: pending.confirmation, summary: pending.summary,
                    confirmTitle: "Apply Charge Limit", onClose: { model.dismissPendingChargeChange() }
                )
                .accessibilityIdentifier("charge-plan-confirmation")
            } else if model.chargeBusy {
                SymairaLoadingState("Planning the change…")
            } else if let failure = model.chargeFailure {
                SymairaNotice(message: failure, tone: .critical)
                    .accessibilityIdentifier("charge-error")
            } else {
                note(status)
            }
        }
    }

    private var status: String {
        switch model.chargeLimitThisSession {
        case .none: "The limit in force cannot be read. This shows only what you apply here."
        case .some(.none): "The limit was removed in this session."
        case .some(.some(let value)): "Limit of \(value) % applied in this session."
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .symairaText(.caption)
            .foregroundStyle(SymairaTokens.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

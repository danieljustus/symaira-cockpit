import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Shared window/popover summary. Display visibility never changes history consent.
struct AIUsageLocalRecordedSpendView: View {
    let model: AIUsageViewModel
    @ObservedObject var preferences: AIUsagePreferences

    var body: some View {
        let spend = model.localRecordedSpend
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text(spend.title).symairaText(.sectionLabel)
            Text("Local-machine data is unattributed, not account billing. Cloud quotas and balances are excluded.")
                .symairaText(.caption).foregroundStyle(SymairaTokens.ink2)
            ForEach(model.rows.filter { preferences.consentedHistoryProviders.contains($0.id) && $0.recordedHistory?.priceSnapshot != nil }) { row in
                if let snapshot = row.recordedHistory?.priceSnapshot {
                    DisclosureGroup("\(row.displayName) Frozen Price Provenance") {
                        Text("Frozen OpenUsage API-rate estimates, not current billing or subscription charges. LiteLLM/models.dev: July 2, 2026; supplement: October 16, 2026.")
                            .symairaText(.caption)
                        Text(snapshot).symairaText(.caption).textSelection(.enabled)
                    }.symairaText(.caption)
                }
            }
            SymairaSegmentedControl("Recorded Spend Period", selection: $preferences.localSpendPeriod,
                options: AIUsageLocalRecordedSpend.Period.allCases.map { (value: $0, label: $0.title) })
            SymairaSegmentedControl("Recorded Spend Measure", selection: $preferences.localSpendMode,
                options: AIUsageLocalRecordedSpend.Mode.allCases.map { (value: $0, label: $0.title) })
                .help(spend.includesEstimates ? "Cost / 1M includes frozen API-rate estimates, not actual charges." :
                    "Cost / 1M: USD per million recorded tokens, derived from recorded cost and tokens; not a price estimate.")
            if model.isRefreshing {
                Text("Refreshing local history…").symairaText(.caption)
            }
            if let total = spend.total {
                Text(spend.formatted(total)).symairaText(.body).monospacedDigit()
                    .textSelection(.enabled)
            } else {
                Text(spend.contributions.isEmpty ? "No Data" : "Incomplete / No Data").symairaText(.body)
            }
            SymairaStatusLabel(spend.message, tone: spend.total == nil ? .neutral : .positive)
            ForEach(spend.contributions) { contribution in
                VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                    Text("\(providerName(contribution.id)): \(contribution.value.map { spend.formatted($0, estimated: contribution.includesEstimates) } ?? "No complete value")")
                        .symairaText(.body).monospacedDigit()
                    Text(contribution.detail).symairaText(.caption).foregroundStyle(SymairaTokens.ink2)
                }
            }
            if let timezone = spend.timezone {
                Text("Calendar: \(timezone == "local" ? "Brain host local time" : timezone). Only consented Claude/Codex/Grok/OpenCode history is included, even when its card is hidden.")
                    .symairaText(.caption).foregroundStyle(SymairaTokens.ink2)
            }
        }
        .foregroundStyle(SymairaTokens.ink)
        .fixedSize(horizontal: false, vertical: true)
        .symairaCard(padding: SymairaSpacing.small)
        .accessibilityIdentifier("local-recorded-spend")
    }

    private func providerName(_ id: String) -> String {
        model.providers.first { $0.id == id }?.displayName ?? id
    }
}

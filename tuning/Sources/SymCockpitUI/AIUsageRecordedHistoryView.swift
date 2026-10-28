import Charts
import SwiftUI
import SymCockpitCore
import SymairaTheme

struct AIUsageRecordedHistoryView: View {
    let history: AIUsageRecordedHistory
    let providerName: String
    private let periods = [("today", "Today"), ("yesterday", "Yesterday"), ("last_30_days", "30 Days")]

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            SymairaFormDivider()
            Text(history.includesEstimates ? "Local History · Recorded + Estimated · Unattributed" : "Local Recorded History · Unattributed").symairaText(.sectionLabel)
            Text("Recorded on this machine, not account billing. Calendar: \(history.timezone == "local" ? "Brain host local time" : history.timezone).")
                .symairaText(.caption).foregroundStyle(SymairaTokens.ink2)
            if let snapshot = history.priceSnapshot {
                DisclosureGroup("Frozen Price Provenance") {
                    Text("Frozen API-rate estimates, not current prices, historical invoices or subscription charges. "
                         + "OpenUsage MIT data; LiteLLM/models.dev retrieved July 2, 2026; supplement updated October 16, 2026.")
                        .symairaText(.caption)
                    Text(snapshot).symairaText(.caption).textSelection(.enabled)
                        .accessibilityLabel("Bundled price snapshot: \(snapshot)")
                }.symairaText(.caption)
            }
            SymairaStatusLabel(statusText, tone: history.status == .partial ? .warning : .neutral)
            if history.status == .available || history.status == .partial {
                ForEach(periods, id: \.0) { key, title in
                    period(key: key, title: title)
                }
                trend
                DisclosureGroup(history.includesEstimates ? "Daily Recorded + Estimated Values" : "Recorded Daily Values") {
                    ForEach(history.daily, id: \.key) { bucket in
                        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                            Text("\(bucket.key) · \(history.summary(bucket))").symairaText(.caption).monospacedDigit()
                            modelRows(bucket)
                        }
                    }
                }.symairaText(.caption)
            }
        }
        .foregroundStyle(SymairaTokens.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("\(providerName.lowercased())-recorded-history")
    }

    private var statusText: String {
        switch history.status {
        case .available: return "Recorded data available · \(history.excludedEvents) excluded events"
        case .partial: return "Incomplete local data · \(history.excludedEvents) excluded events; complete cost totals withheld"
        case .noData: return "No recorded data. Complete a \(providerName) session, then refresh. \(history.excludedEvents) excluded events."
        case .unavailable: return "Local history unavailable. Refresh to retry; no earlier totals are shown."
        }
    }

    private func period(key: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            Text(title).symairaText(.sectionLabel)
            if let bucket = history.periods.first(where: { $0.key == key }) {
                Text(history.summary(bucket)).symairaText(.body).monospacedDigit()
                if bucket.models.contains(where: { $0.costBasis != nil }) {
                    Text(history.costDetail(bucket)).symairaText(.caption).monospacedDigit()
                }
                DisclosureGroup("\(title) Models (\(bucket.models.count))") { modelRows(bucket) }
                    .symairaText(.caption)
            } else {
                Text("No recorded data for this period — not zero.").symairaText(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), local unattributed recorded usage")
    }

    private func modelRows(_ bucket: AIUsageRecordedHistory.Bucket) -> some View {
        ForEach(bucket.models, id: \.model) { row in
            Text(row.detail)
                .symairaText(.caption).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.detail)
                .accessibilityLabel(row.detail)
                .textSelection(.enabled)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            Text(history.includesEstimates ? "30-Day Cost Trend (USD, Includes Estimates)" : "30-Day Recorded Cost Trend (USD)").symairaText(.sectionLabel)
            if history.daily.contains(where: { history.total($0, cost: true) != nil }) {
                Chart(history.daily, id: \.key) { bucket in
                    if let amount = history.total(bucket, cost: true) {
                        BarMark(x: .value("Recorded date", bucket.key),
                                y: .value(history.costLabel(for: bucket) + " USD", NSDecimalNumber(decimal: amount).doubleValue), width: .fixed(12))
                            .foregroundStyle(SymairaTokens.selected)
                            .accessibilityLabel("\(bucket.key), local unattributed \(history.costLabel(for: bucket)) cost")
                            .accessibilityValue(Text(String(describing: amount) + " USD"))
                    }
                }
                .frame(height: 100)
                .accessibilityLabel("30-day local unattributed \(history.costLabel) cost trend")
            } else {
                Text("No complete daily costs to plot. Inspect recorded model values below.").symairaText(.caption)
            }
            Text("Only recorded dates are shown; missing dates are unknown, not zero. Exact values are in Recorded Daily Values.")
                .symairaText(.caption).foregroundStyle(SymairaTokens.ink2)
        }
    }
}

struct AIUsageHistoryConsent: View {
    @ObservedObject var preferences: AIUsagePreferences
    var body: some View {
        SymairaFormSection("Local Claude History", footer:
            "Off by default. Reads local Claude Code session usage only when Claude is enabled. "
            + "Local-machine data is unattributed, not your account bill. Recorded costs remain separate from frozen API-rate estimates.") {
            SymairaFormRow("Read Local Session Usage") {
                Toggle("Read Local Claude Session Usage", isOn: $preferences.claudeHistoryEnabled)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Read local Claude session usage, unattributed")
            }
            SymairaFormRow("Claude History Only", description:
                "Only with Claude history enabled: skip Claude quota credentials and requests. Other providers are unchanged. Turning this off restores the existing Claude quota behavior.") {
                Toggle("Claude History Only", isOn: $preferences.claudeHistoryOnly)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Claude history only, skip Claude quota credentials and requests")
            }
        }
        SymairaFormSection("Local Codex History", footer:
            "Off by default. Reads local Codex session usage only when Codex is enabled. "
            + "Local-machine data is unattributed, not your account bill. Recorded costs remain separate from frozen API-rate estimates.") {
            SymairaFormRow("Read Local Session Usage") {
                Toggle("Read Local Codex Session Usage", isOn: $preferences.codexHistoryEnabled)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Read local Codex session usage, unattributed")
            }
            SymairaFormRow("Codex History Only", description:
                "Only with Codex history enabled: skip Codex quota credentials and requests. Other providers are unchanged. Turning this off restores the existing Codex quota behavior.") {
                Toggle("Codex History Only", isOn: $preferences.codexHistoryOnly)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Codex history only, skip Codex quota credentials and requests")
            }
        }
        SymairaFormSection("Local Grok History", footer:
            "Off by default. Reads local Grok session usage only when Grok is enabled. "
            + "Local-machine data is unattributed, not your account bill. Recorded amounts only; no estimates.") {
            SymairaFormRow("Read Local Session Usage") {
                Toggle("Read Local Grok Session Usage", isOn: $preferences.grokHistoryEnabled)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Read local Grok session usage, unattributed")
            }
        }
        SymairaFormSection("Local OpenCode History", footer:
            "Off by default. Reads local OpenCode session usage only when OpenCode is enabled. "
            + "Local-machine data is unattributed, not your account bill. Recorded amounts only; no estimates.") {
            SymairaFormRow("Read Local Session Usage") {
                Toggle("Read Local OpenCode Session Usage", isOn: $preferences.opencodeHistoryEnabled)
                    .labelsHidden().toggleStyle(.symairaSwitch)
                    .accessibilityLabel("Read local OpenCode session usage, unattributed")
            }
        }
    }
}

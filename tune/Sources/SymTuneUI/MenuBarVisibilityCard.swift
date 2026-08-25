import SwiftUI
import SymairaTheme
import SymTuneCore

/// Which metrics the menu bar shows — the one Tune preference people change
/// often enough that it should not live behind a Preferences window.
///
/// Two switches per metric, because they are genuinely two decisions:
/// **Monitor** samples the metric (feeding the history sparklines and the
/// panel), **Menu bar** puts it in the status item. Sampling something you do
/// not want in the menu bar is normal; showing something you do not sample is
/// not, so turning the second on turns the first on with it.
///
/// Changes apply to the status item immediately and are written to
/// `config.toml` right away — a menu bar that reverts on the next launch would
/// be worse than one that never changed.
@MainActor
struct MenuBarVisibilityCard: View {
    @ObservedObject var preferences: PreferencesManager
    @ObservedObject var aiUsage: AIUsagePreferences
    let model: TuneViewModel
    /// Whether any AI-usage provider is switched on at all; the menu-bar
    /// toggle for it is meaningless otherwise and says so.
    let hasEnabledAIProviders: Bool

    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            header

            VStack(spacing: SymairaSpacing.xSmall) {
                columnHeaders
                ForEach(preferences.metricOrder, id: \.self) { metric in
                    metricRow(metric)
                }
                calendarWeekRow
            }

            Divider().overlay(SymairaTheme.borderGlass)

            aiUsageRow

            if let saveError {
                Text(saveError)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MENU BAR")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                Text("What the status item shows")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            Spacer(minLength: SymairaSpacing.small)
            preview
        }
    }

    /// The switch columns are named once, at the top. Repeating the two
    /// captions under every row turned a four-row list into eight lines of
    /// the same two words.
    private var columnHeaders: some View {
        HStack(spacing: SymairaSpacing.medium) {
            Spacer(minLength: 0)
            Text("Monitor")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textMuted)
                .frame(width: 64)
            Text("Menu bar")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textMuted)
                .frame(width: 64)
        }
    }

    /// A live rendering of the status item's current text, so the effect of a
    /// switch is visible without looking up at the menu bar.
    private var preview: some View {
        Group {
            if model.statusItemText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("icon only")
                        .symairaText(.caption)
                }
                .foregroundStyle(SymairaTheme.textMuted)
            } else {
                Text(model.statusItemText)
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTheme.textPrimary)
            }
        }
        .padding(.horizontal, SymairaSpacing.small)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: SymairaRadius.control)
                .fill(SymairaTheme.bgDarker.opacity(0.7))
        )
        .help("What the menu bar shows right now")
    }

    // MARK: - Rows

    private func metricRow(_ metric: MetricIdentifier) -> some View {
        let isMonitored = preferences.enabledMetrics.contains(metric)
        let isVisible = preferences.visibleMetrics.contains(metric)

        return HStack(spacing: SymairaSpacing.medium) {
            Image(systemName: metric.statusItemSymbol)
                .symairaText(.caption)
                .frame(width: 18)
                .foregroundStyle(isVisible ? SymairaTheme.goldPrimary : SymairaTheme.textMuted)

            Text(metric.displayName)
                .symairaText(.body)
                .foregroundStyle(isMonitored ? SymairaTheme.textPrimary : SymairaTheme.textMuted)

            Spacer(minLength: SymairaSpacing.small)

            switchCell(
                isOn: isMonitored,
                help: "Sample \(metric.displayName) for the panel and its history"
            ) { newValue in
                if newValue {
                    preferences.enabledMetrics.insert(metric)
                } else {
                    // A metric that is not sampled has nothing to show, so it
                    // leaves the menu bar with it.
                    preferences.enabledMetrics.remove(metric)
                    preferences.visibleMetrics.remove(metric)
                }
                applyChange()
            }

            switchCell(
                isOn: isVisible,
                help: "Show \(metric.displayName) in the menu bar"
            ) { newValue in
                if newValue {
                    // Showing implies sampling.
                    preferences.enabledMetrics.insert(metric)
                    preferences.visibleMetrics.insert(metric)
                } else {
                    preferences.visibleMetrics.remove(metric)
                }
                applyChange()
            }
        }
    }

    private var calendarWeekRow: some View {
        HStack(spacing: SymairaSpacing.medium) {
            Image(systemName: "calendar")
                .symairaText(.caption)
                .frame(width: 18)
                .foregroundStyle(
                    preferences.showCalendarWeek
                        ? SymairaTheme.goldPrimary
                        : SymairaTheme.textMuted
                )

            Text("Calendar week")
                .symairaText(.body)
                .foregroundStyle(SymairaTheme.textPrimary)

            Spacer(minLength: SymairaSpacing.small)

            // Calendar week is a display-only segment, so it has no monitor
            // switch; keep the toggle aligned with the other menu-bar switches.
            Color.clear.frame(width: 64, height: 1)

            switchCell(
                isOn: preferences.showCalendarWeek,
                help: "Show the current ISO-8601 calendar week in the menu bar"
            ) { newValue in
                preferences.showCalendarWeek = newValue
                applyChange()
            }
        }
    }

    private var aiUsageRow: some View {
        HStack(spacing: SymairaSpacing.medium) {
            Image(systemName: "sparkles")
                .symairaText(.caption)
                .frame(width: 18)
                .foregroundStyle(
                    aiUsage.menuBarEnabled && hasEnabledAIProviders
                        ? SymairaTheme.goldPrimary
                        : SymairaTheme.textMuted
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("AI usage")
                    .symairaText(.body)
                    .foregroundStyle(hasEnabledAIProviders ? SymairaTheme.textPrimary : SymairaTheme.textMuted)
                if !hasEnabledAIProviders {
                    Text("No provider enabled — turn one on in Preferences")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }

            Spacer(minLength: SymairaSpacing.small)

            // Nothing to sample here — the AI providers have their own
            // refresh loop — so the row sits under the "Menu bar" column only.
            Color.clear.frame(width: 64, height: 1)

            switchCell(
                isOn: aiUsage.menuBarEnabled,
                help: "Append the active provider's usage to the menu bar",
                disabled: !hasEnabledAIProviders
            ) { newValue in
                // Stored in UserDefaults by AIUsagePreferences itself, so
                // there is nothing to write to config.toml here.
                aiUsage.menuBarEnabled = newValue
            }
        }
    }

    /// One switch under one of the two named columns.
    private func switchCell(
        isOn: Bool,
        help: String,
        disabled: Bool = false,
        set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(SymairaTheme.goldPrimary)
            .frame(width: 64)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
            .help(help)
    }

    // MARK: - Applying

    /// Push the change into the running status item and persist it.
    ///
    /// The status item otherwise picks the change up on its next tick, which
    /// at the idle cadence is up to ten seconds later — long enough to read as
    /// a switch that did nothing.
    private func applyChange() {
        model.syncEnabledMetrics()
        model.refreshNow()
        do {
            try preferences.writeToConfig()
            saveError = nil
        } catch {
            saveError = "Could not save to config.toml: \(error.localizedDescription)"
        }
    }
}

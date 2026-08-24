import SwiftUI
import SymairaTheme
import SymairaUpdateCheck
import SymTuneCore

/// Preferences window for configuring which system metrics are monitored,
/// shown in the menu bar, their order, refresh interval, and display units.
struct PreferencesView: View {
    @ObservedObject var manager: PreferencesManager
    let autoPrefs: UserDefaultsAutoUpdatePreferenceStore
    @ObservedObject var aiUsage: AIUsagePreferences
    let aiUsageProviders: [any AIUsageProvider]
    /// Called after an AI-usage credential is saved or cleared, so the
    /// caller can drop the cache and refresh immediately (issue #324).
    let onCredentialChange: () -> Void

    @State private var refreshText: String = ""
    @State private var applyMessage: String?
    @State private var applySuccess: Bool = false
    @AppStorage("com.symaira.symtune.autoCheckEnabled") private var autoCheckEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(SymairaTheme.borderGlass)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Metrics list with toggles and ordering
                    metricsSection

                    Divider()
                        .background(SymairaTheme.borderGlass)

                    // Which cards the popover shows
                    cardsSection

                    Divider()
                        .background(SymairaTheme.borderGlass)

                    // Refresh interval
                    refreshIntervalSection

                    Divider()
                        .background(SymairaTheme.borderGlass)

                    // Units
                    unitsSection

                    Divider()
                        .background(SymairaTheme.borderGlass)

                    // AI usage providers (toggles, API keys, menu-bar readout)
                    AIUsagePreferencesSection(
                        preferences: aiUsage,
                        providers: aiUsageProviders,
                        onCredentialChange: onCredentialChange
                    )

                    Divider()
                        .background(SymairaTheme.borderGlass)

                    // Auto-update
                    updateSection
                }
                .padding(SymairaSpacing.xLarge)
            }

            Divider()
                .background(SymairaTheme.borderGlass)

            // Footer with apply button
            footerView
        }
        .frame(width: 560, height: 560)
        .background(SymairaTheme.bgDark)
        .onAppear {
            refreshText = String(format: "%.1f", manager.metricsRefreshInterval)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preferences")
                    .symairaText(.heading)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                Text("System Metrics")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, SymairaSpacing.xLarge)
        .padding(.vertical, SymairaSpacing.large)
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MONITORED METRICS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)

            Text("Drag to reorder, toggle to enable/disable or show/hide in the menu bar.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)

            // Metric rows
            VStack(spacing: 6) {
                ForEach(manager.metricOrder, id: \.self) { metric in
                    metricRow(metric)
                }
            }
        }
    }

    private func metricRow(_ metric: MetricIdentifier) -> some View {
        let isEnabled = manager.enabledMetrics.contains(metric)
        let isVisible = manager.visibleMetrics.contains(metric)
        let isFirst = manager.metricOrder.first == metric
        let isLast = manager.metricOrder.last == metric

        let row = HStack(spacing: 10) {
            // Move up/down buttons
            VStack(spacing: 2) {
                Button(action: { moveMetric(metric, up: true) }, label: {
                    Image(systemName: "chevron.up")
                        .symairaText(.caption)
                        .frame(width: 20, height: 14)
                })
                .buttonStyle(.plain)
                .disabled(isFirst)
                .opacity(isFirst ? 0.3 : 0.8)
                .foregroundStyle(SymairaTheme.textSecondary)

                Button(action: { moveMetric(metric, up: false) }, label: {
                    Image(systemName: "chevron.down")
                        .symairaText(.caption)
                        .frame(width: 20, height: 14)
                })
                .buttonStyle(.plain)
                .disabled(isLast)
                .opacity(isLast ? 0.3 : 0.8)
                .foregroundStyle(SymairaTheme.textSecondary)
            }

            // Metric name
            Text(metric.displayName)
                .symairaText(.caption)
                .foregroundStyle(isEnabled ? SymairaTheme.textPrimary : SymairaTheme.textMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 60, alignment: .leading)

            Spacer()

            // Enable/disable toggle
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        manager.enabledMetrics.insert(metric)
                    } else {
                        manager.enabledMetrics.remove(metric)
                        manager.visibleMetrics.remove(metric)
                    }
                }
            )) {
                Text("Monitor")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.switch)
            .frame(width: 100)

            // Show/hide toggle
            Toggle(isOn: Binding(
                get: { isVisible },
                set: { newValue in
                    if newValue {
                        manager.enabledMetrics.insert(metric)
                        manager.visibleMetrics.insert(metric)
                    } else {
                        manager.visibleMetrics.remove(metric)
                    }
                }
            )) {
                Text("Show")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.switch)
            .frame(width: 80)
            .disabled(!isEnabled)
        }

        return VStack(alignment: .leading, spacing: 8) {
            row
            // Style controls only matter for a metric that is actually in the
            // menu bar, so they appear with it rather than sitting there inert.
            if isVisible {
                MetricStyleRow(manager: manager, metric: metric)
            }
        }
        .padding(.horizontal, SymairaSpacing.medium)
        .padding(.vertical, SymairaSpacing.small)
        .background(SymairaTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.card)
                .stroke(isEnabled ? SymairaTheme.borderGlass : SymairaTheme.borderGlass.opacity(0.3), lineWidth: 1)
        )
    }

    private func moveMetric(_ metric: MetricIdentifier, up: Bool) {
        guard let index = manager.metricOrder.firstIndex(of: metric) else { return }
        let newIndex = up ? max(0, index - 1) : min(manager.metricOrder.count - 1, index + 1)
        guard newIndex != index else { return }
        manager.metricOrder.move(fromOffsets: IndexSet(integer: index), toOffset: newIndex > index ? newIndex + 1 : newIndex)
    }

    // MARK: - Popover Cards

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POPOVER CARDS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)

            Text("Choose which cards appear when you open the panel.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)

            ForEach(PopoverCard.allCases, id: \.self) { card in
                Toggle(isOn: Binding(
                    get: { manager.visibleCards.contains(card) },
                    set: { newValue in
                        if newValue {
                            manager.visibleCards.insert(card)
                        } else {
                            manager.visibleCards.remove(card)
                        }
                    }
                )) {
                    Text(card.displayName)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Refresh Interval

    private var refreshIntervalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFRESH INTERVAL")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)

            HStack(spacing: 12) {
                Text("Sample every")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()

                TextField("", text: $refreshText)
                    .textFieldStyle(.symaira)
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTheme.textPrimary)
                    .frame(width: 50)
                    .onChange(of: refreshText) { _, newValue in
                        if let value = TimeInterval(newValue),
                           value >= TuneConfig.minimumRefreshInterval {
                            manager.metricsRefreshInterval = value
                        }
                    }

                Text("seconds")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()

                Spacer()

                // Quick presets
                ForEach([1.0, 3.0, 5.0, 10.0], id: \.self) { preset in
                    Button(action: {
                        manager.metricsRefreshInterval = preset
                        refreshText = String(format: "%.0f", preset)
                    }, label: {
                        Text("\(Int(preset))s")
                            .symairaText(.monoSmall)
                            .foregroundStyle(
                                abs(manager.metricsRefreshInterval - preset) < 0.01
                                    ? SymairaTheme.bgDark
                                    : SymairaTheme.textSecondary
                            )
                            .padding(.horizontal, SymairaSpacing.small)
                            .padding(.vertical, SymairaSpacing.xSmall)
                            .background(
                                abs(manager.metricsRefreshInterval - preset) < 0.01
                                    ? SymairaTheme.goldPrimary
                                    : SymairaTheme.bgCard
                            )
                            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    })
                    .buttonStyle(.plain)
                }
            }

            // Minimum interval note
            HStack {
                Image(systemName: "info.circle.fill")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                Text("Minimum refresh interval is \(String(format: "%.0f", TuneConfig.minimumRefreshInterval)) second")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISPLAY UNITS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)

            HStack(spacing: 24) {
                // Network unit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Throughput")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                        .lineLimit(1)
                        .fixedSize()

                    Picker("", selection: $manager.networkUnit) {
                        ForEach(NetworkUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                Spacer()

                // Temperature unit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                        .lineLimit(1)
                        .fixedSize()

                    Picker("", selection: $manager.temperatureUnit) {
                        ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
        }
    }

    // MARK: - Auto-Update Section

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UPDATE CHECK")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)

            HStack {
                Toggle(isOn: $autoCheckEnabled) {
                    Text("Check for updates automatically")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.switch)
                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Apply message
            if let message = applyMessage {
                HStack(spacing: 4) {
                    Image(systemName: applySuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .symairaText(.caption)
                        .foregroundStyle(applySuccess ? SymairaTheme.positive : SymairaTheme.critical)
                    Text(message)
                        .symairaText(.caption)
                        .foregroundStyle(applySuccess ? SymairaTheme.positive : SymairaTheme.critical)
                }
            }

            Spacer()

            Button(action: {
                NSApp.keyWindow?.close()
            }, label: {
                Text("Close")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .padding(.horizontal, SymairaSpacing.large)
                    .padding(.vertical, SymairaSpacing.small)
                    .background(SymairaTheme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: SymairaRadius.control)
                            .stroke(SymairaTheme.borderGlass, lineWidth: 1)
                    )
            })
            .buttonStyle(.plain)

            Button(action: applyPreferences) {
                Text("Apply & Save")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.bgDark)
                    .padding(.horizontal, SymairaSpacing.large)
                    .padding(.vertical, SymairaSpacing.small)
                    .background(SymairaTheme.goldPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SymairaSpacing.xLarge)
        .padding(.vertical, SymairaSpacing.medium)
    }

    // MARK: - Actions

    private func applyPreferences() {
        do {
            try manager.writeToConfig()
            applyMessage = "Preferences saved — changes take effect immediately."
            applySuccess = true
        } catch {
            applyMessage = "Failed to save preferences: \(error.localizedDescription)"
            applySuccess = false
        }

        // Clear message after a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            applyMessage = nil
        }
    }
}

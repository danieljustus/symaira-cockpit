import SwiftUI
import SymairaTheme
import SymairaUpdateCheck
import SymCockpitCore

/// Preferences window for configuring which system metrics are monitored,
/// shown in the menu bar, their order, refresh interval, and display units.
struct PreferencesView: View {
    @ObservedObject var manager: PreferencesManager
    @Bindable var appearance: CockpitAppearancePreferences
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
                .background(SymairaTokens.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceSection

                    Divider()
                        .background(SymairaTokens.line)

                    // Metrics list with toggles and ordering
                    metricsSection

                    Divider()
                        .background(SymairaTokens.line)

                    // Which cards the popover shows
                    cardsSection

                    Divider()
                        .background(SymairaTokens.line)

                    // Refresh interval
                    refreshIntervalSection

                    Divider()
                        .background(SymairaTokens.line)

                    // Units
                    unitsSection

                    Divider()
                        .background(SymairaTokens.line)

                    // AI usage providers (toggles, API keys, menu-bar readout)
                    AIUsagePreferencesSection(
                        preferences: aiUsage,
                        providers: aiUsageProviders,
                        onCredentialChange: onCredentialChange
                    )

                    Divider()
                        .background(SymairaTokens.line)

                    // Auto-update
                    updateSection
                }
                .padding(SymairaSpacing.xLarge)
            }

            Divider()
                .background(SymairaTokens.line)

            // Footer with apply button
            footerView
        }
        .frame(width: 640, height: 560)
        .background(SymairaTokens.canvas)
        .tint(SymairaTokens.selected)
        .onAppear {
            refreshText = String(manager.metricsRefreshInterval)
        }
        .task(id: applyMessage) {
            // Errors stay until corrected; a new message cancels an old success timer.
            guard applySuccess, applyMessage != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            applyMessage = nil
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preferences")
                    .symairaText(.title, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                Text("Appearance & System Metrics")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, SymairaSpacing.xLarge)
        .padding(.vertical, SymairaSpacing.large)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPEARANCE")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)
            SymairaSegmentedControl(
                "Appearance", selection: $appearance.selection,
                options: CockpitAppearance.allCases.map { ($0, $0.title) }
            )
            .accessibilityIdentifier("cockpit-appearance")
            Text("Saved automatically. System follows macOS.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink2)
        }
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MONITORED METRICS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)

            Text("Drag to reorder, toggle to enable/disable or show/hide in the menu bar.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink2)

            // Metric rows
            VStack(spacing: 6) {
                ForEach(manager.metricOrder, id: \.self) { metric in
                    metricRow(metric)
                }
                calendarWeekRow
            }
        }
    }

    /// The calendar week is a display-only menu-bar segment: nothing samples
    /// it and nothing orders it, so it gets the "Show" switch alone and sits
    /// below the metrics rather than among them.
    private var calendarWeekRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .symairaText(.caption)
                .frame(width: 20)
                .foregroundStyle(
                    manager.showCalendarWeek
                        ? SymairaTokens.selected
                        : SymairaTokens.ink3
                )

            Text("Calendar week")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 60, alignment: .leading)

            Spacer()

            // Keeps the switch under the metric rows' "Show" column.
            Color.clear.frame(width: 116, height: 1)

            Toggle(isOn: $manager.showCalendarWeek) {
                Text("Show")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.symairaSwitch)
            .frame(width: 104)
            .accessibilityLabel("Show calendar week in menu bar")
            .help("Show the current ISO-8601 calendar week in the menu bar")
        }
        .padding(.horizontal, SymairaSpacing.medium)
        .padding(.vertical, SymairaSpacing.small)
        .background(SymairaTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.card)
                .stroke(SymairaTokens.line, lineWidth: 1)
        )
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
                .accessibilityLabel("Move \(metric.displayName) up")
                .disabled(isFirst)
                .opacity(isFirst ? 0.3 : 0.8)
                .foregroundStyle(SymairaTokens.ink2)

                Button(action: { moveMetric(metric, up: false) }, label: {
                    Image(systemName: "chevron.down")
                        .symairaText(.caption)
                        .frame(width: 20, height: 14)
                })
                .buttonStyle(.plain)
                .accessibilityLabel("Move \(metric.displayName) down")
                .disabled(isLast)
                .opacity(isLast ? 0.3 : 0.8)
                .foregroundStyle(SymairaTokens.ink2)
            }

            // Metric name
            Text(metric.displayName)
                .symairaText(.caption)
                .foregroundStyle(isEnabled ? SymairaTokens.ink : SymairaTokens.ink3)
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
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.symairaSwitch)
            .frame(width: 116)
            .accessibilityLabel("Monitor \(metric.displayName)")

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
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.symairaSwitch)
            .frame(width: 104)
            .accessibilityLabel("Show \(metric.displayName) in menu bar")
            .disabled(!isEnabled)
        }

        return VStack(alignment: .leading, spacing: 8) {
            row
            // Style controls follow "Monitor", not "Show": they drive the
            // System Metrics card as well as the menu bar, so a metric that is
            // measured but kept out of the menu bar still has something to
            // configure.
            if isEnabled {
                MetricStyleRow(manager: manager, metric: metric)
            }
        }
        .padding(.horizontal, SymairaSpacing.medium)
        .padding(.vertical, SymairaSpacing.small)
        .background(SymairaTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.card)
                .stroke(isEnabled ? SymairaTokens.line : SymairaTokens.line.opacity(0.3), lineWidth: 1)
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
                .foregroundStyle(SymairaTokens.ink3)

            Text("Choose which cards appear when you open the panel.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink2)

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
                        .foregroundStyle(SymairaTokens.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.symairaSwitch)
            }
        }
    }

    // MARK: - Refresh Interval

    private var validRefreshInterval: TimeInterval? {
        TuneConfig.validatedRefreshInterval(refreshText)
    }

    private var refreshIntervalHint: String {
        "Enter \(Int(TuneConfig.minimumRefreshInterval))–\(Int(TuneConfig.maximumRefreshInterval)) seconds (e.g. 3.5)."
    }

    private var refreshIntervalError: String? {
        validRefreshInterval == nil ? "Refresh interval: \(refreshIntervalHint)" : nil
    }

    private var refreshIntervalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFRESH INTERVAL")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)

            HStack(spacing: 12) {
                Text("Sample every")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()

                TextField("", text: $refreshText)
                    .textFieldStyle(.symaira)
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTokens.ink)
                    .frame(width: 80)
                    .accessibilityLabel("Refresh interval in seconds")
                    .help(refreshIntervalHint)
                    .onChange(of: refreshText) { _, newValue in
                        applyMessage = nil
                        applySuccess = false
                        if let value = TuneConfig.validatedRefreshInterval(newValue) {
                            manager.metricsRefreshInterval = value
                        }
                    }

                Text("seconds")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
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
                                    ? SymairaTokens.onSelected
                                    : SymairaTokens.ink2
                            )
                            .padding(.horizontal, SymairaSpacing.small)
                            .padding(.vertical, SymairaSpacing.xSmall)
                            .background(
                                abs(manager.metricsRefreshInterval - preset) < 0.01
                                    ? SymairaTokens.selected
                                    : SymairaTokens.raised
                            )
                            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    })
                    .buttonStyle(.plain)
                }
            }

            // Keep the range visible next to the editable value.
            HStack {
                Image(systemName: "info.circle.fill")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                Text(refreshIntervalHint)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            }
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISPLAY UNITS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)

            HStack(spacing: 24) {
                // Network unit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Throughput")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                        .lineLimit(1)
                        .fixedSize()

                    SymairaSegmentedControl(
                        "Network throughput unit", selection: $manager.networkUnit,
                        options: NetworkUnit.allCases.map { ($0, $0.displayName) }
                    )
                    .frame(width: 180)
                }

                Spacer()

                // Temperature unit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                        .lineLimit(1)
                        .fixedSize()

                    SymairaSegmentedControl(
                        "Temperature unit", selection: $manager.temperatureUnit,
                        options: TemperatureUnit.allCases.map { ($0, $0.displayName) }
                    )
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
                .foregroundStyle(SymairaTokens.ink3)

            HStack {
                Toggle(isOn: $autoCheckEnabled) {
                    Text("Check for updates automatically")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.symairaSwitch)
                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Validation stays visible even when the input has scrolled out of view.
            if let message = refreshIntervalError ?? applyMessage {
                HStack(spacing: 4) {
                    Image(systemName: applySuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .symairaText(.caption)
                        .foregroundStyle(applySuccess ? SymairaTokens.positive : SymairaTokens.critical)
                    Text(message)
                        .symairaText(.caption)
                        .foregroundStyle(applySuccess ? SymairaTokens.positive : SymairaTokens.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button(action: {
                NSApp.keyWindow?.close()
            }, label: {
                Text("Close")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .padding(.horizontal, SymairaSpacing.large)
                    .padding(.vertical, SymairaSpacing.small)
                    .background(SymairaTokens.surface)
                    .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: SymairaRadius.control)
                            .stroke(SymairaTokens.line, lineWidth: 1)
                    )
            })
            .buttonStyle(.plain)

            Button(action: applyPreferences) {
                Text("Apply & Save")
            }
            .symairaButtonStyle(.primary)
            .disabled(validRefreshInterval == nil)
            .opacity(validRefreshInterval == nil ? 0.45 : 1)
            .help(refreshIntervalError ?? "Save preferences")
        }
        .padding(.horizontal, SymairaSpacing.xLarge)
        .padding(.vertical, SymairaSpacing.medium)
    }

    // MARK: - Actions

    private func applyPreferences() {
        guard let interval = validRefreshInterval else { return }
        manager.metricsRefreshInterval = interval
        do {
            try manager.writeToConfig()
            applyMessage = "Preferences saved — changes take effect immediately."
            applySuccess = true
        } catch {
            applyMessage = "Failed to save preferences: \(error.localizedDescription)"
            applySuccess = false
        }
    }
}

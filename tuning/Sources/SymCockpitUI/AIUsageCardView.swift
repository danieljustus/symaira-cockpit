import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Shared by the window and popover; customization edits the same persisted preferences.
@MainActor
struct AIUsageCardView: View {
    let model: AIUsageViewModel
    @ObservedObject private var preferences: AIUsagePreferences
    @State private var customizing = false
    @State private var selectedProvider: String?
    @State private var pinNotice = false
    @State private var confirmingReset = false
    @State private var resetProvider: String?
    @State private var shareNotice: String?
    @Environment(\.colorScheme) private var colorScheme

    init(model: AIUsageViewModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Usage", systemImage: "sparkles").font(.headline)
                Spacer()
                Button(customizing ? "Done" : "Customize…") { customizing.toggle() }
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshNow() }
                    .labelStyle(.iconOnly).help("Refresh enabled AI providers")
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("Undo customization") { preferences.undoManager.undo() }
                        .disabled(!preferences.undoManager.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button("Reset all customization…") {
                        resetProvider = nil
                        confirmingReset = true
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("AI usage actions")
            }
            if customizing {
                customization
            } else {
                AIUsageLocalRecordedSpendView(model: model, preferences: preferences)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.visibleRows) { row in providerCard(row, now: context.date) }
                    }
                }
                if model.visibleRows.isEmpty {
                    Text("Choose providers in Customize to show usage.").foregroundStyle(.secondary)
                }
            }
            if pinNotice { Text("Up to 2 stars per provider. Unstar a metric first.").font(.caption) }
            if let shareNotice { Text(shareNotice).font(.caption) }
        }
        .confirmationDialog("Reset AI usage customization?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { preferences.resetCustomization(providerID: resetProvider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resets layout and stars. Enabled providers, credentials and cached usage are kept. This cannot be undone.")
        }
    }

    private func customize(_ id: String) {
        selectedProvider = id
        customizing = true
    }

    private func star(_ metric: AIUsageMetric, row: AIUsageRow) {
        pinNotice = !preferences.layout.togglePin(metric.id, provider: row.id)
    }

    private func share(_ row: AIUsageRow) {
        let metrics = visibleMetrics(row, onDemand: false)
            + (preferences.layout.expanded.contains(row.id) ? visibleMetrics(row, onDemand: true) : [])
        let card = AIUsageShareCard(row: row, metrics: metrics, layout: preferences.layout, now: Date())
        guard let png = card.png(appearance: colorScheme) else {
            shareNotice = "Could not render usage image."
            return
        }
        NSPasteboard.general.clearContents()
        shareNotice = NSPasteboard.general.setData(png, forType: .png)
            ? "Usage image copied. It contains the visible usage values."
            : "Could not copy usage image."
    }

    private func providerCard(_ row: AIUsageRow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.displayName).font(.headline)
                if let source = row.snapshot?.source { Text("via \(source)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if row.error != nil {
                    Text(row.isStale ? "Stale cached usage" : (row.recordedHistory != nil ? "Quota source unavailable" : "Source unavailable"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .draggable("provider:\(row.id)")
            .dropDestination(for: String.self) { items, _ in return dropProvider(items, target: row.id) }
            .contextMenu {
                Button("Hide provider") { preferences.setVisibility(row.id, visible: false) }
                Button("Share screenshot") { share(row) }
                Button("Refresh \(row.displayName)") { model.refreshNow(providerID: row.id) }
                Button("Customize…") { customize(row.id) }
                Button("Reset provider customization…") {
                    resetProvider = row.id
                    confirmingReset = true
                }
                providerMoves(row.id)
            }
            if let error = row.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                if let date = row.lastSuccessAt {
                    Text("Last success: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(visibleMetrics(row, onDemand: false)) { metric in
                metricRow(metric, row: row, now: now)
            }
            if preferences.layout.expanded.contains(row.id) {
                if !visibleMetrics(row, onDemand: true).isEmpty { Divider() }
                ForEach(visibleMetrics(row, onDemand: true)) { metric in
                    metricRow(metric, row: row, now: now)
                }
                HStack {
                    ForEach(AIUsageProviderLink.links(for: row.id)) { link in
                        Link(link.title, destination: link.url).font(.caption)
                    }
                }
            }
            if !visibleMetrics(row, onDemand: true).isEmpty || !AIUsageProviderLink.links(for: row.id).isEmpty {
                Button(preferences.layout.expanded.contains(row.id) ? "Show less" : "Show on-demand metrics") {
                    toggle(row.id, in: &preferences.layout.expanded)
                }.font(.caption)
            }
            if let snapshot = row.snapshot {
                if let empty = AIUsageFormatting.emptySnapshotText(for: snapshot) { Text(empty).font(.caption) }
            }
            if preferences.consentedHistoryProviders.contains(row.id) {
                if model.isRefreshing {
                    Text("Refreshing local recorded history…").symairaText(.caption)
                }
                if let history = row.recordedHistory {
                    AIUsageRecordedHistoryView(history: history, providerName: row.displayName)
                } else {
                    Text("Local recorded history not returned. Refresh to retry; your Brain version may not support it.")
                        .symairaText(.caption)
                }
            }
            if !row.history.isEmpty {
                SparklineView(samples: row.history, lineColor: SymairaTokens.selected, showAnnotations: false)
                    .frame(height: 22)
            }
        }
        .padding(10)
        .background(SymairaTokens.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func visibleMetrics(_ row: AIUsageRow, onDemand: Bool) -> [AIUsageMetric] {
        model.metrics(for: row).filter {
            !preferences.layout.hidden.contains($0.id) && preferences.layout.onDemand.contains($0.id) == onDemand
        }
    }

    private func metricRow(_ metric: AIUsageMetric, row: AIUsageRow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(metric.meter.label)
                if preferences.layout.pins[row.id]?.contains(metric.id) == true {
                    Image(systemName: "star.fill").accessibilityLabel("Pinned to menu bar")
                }
                Spacer()
                Button {
                    preferences.layout.remaining.toggle()
                } label: {
                    Text(valueText(metric))
                }.buttonStyle(.plain)
                    .help("Switch used / remaining for all metrics")
            }
            if let fraction = metric.fraction(remaining: preferences.layout.remaining) {
                ProgressView(value: fraction).progressViewStyle(CockpitProgressStyle())
                    .accessibilityLabel(metric.meter.label).accessibilityValue(valueText(metric))
            }
            if let reset = metric.reset(absolute: preferences.layout.absoluteReset, now: now) {
                Button(reset) { preferences.layout.absoluteReset.toggle() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Switch countdown / exact reset time for all metrics")
            }
        }
        .font(.caption).monospacedDigit()
        .contentShape(Rectangle())
        .draggable(metric.id)
        .dropDestination(for: String.self) { items, _ in return dropMetric(items, target: metric.id, row: row) }
        .contextMenu {
            Button(preferences.layout.pins[row.id]?.contains(metric.id) == true ? "Unstar" : "Star for menu bar") {
                star(metric, row: row)
            }
            Button("Hide metric") { preferences.layout.hidden.insert(metric.id) }
            Button(preferences.layout.onDemand.contains(metric.id) ? "Always visible" : "Show on demand") {
                toggle(metric.id, in: &preferences.layout.onDemand)
            }
            Button("Refresh \(row.displayName)") { model.refreshNow(providerID: row.id) }
            Button("Customize…") { customize(row.id) }
            metricMoves(metric.id, row: row)
        }
    }

    private func valueText(_ metric: AIUsageMetric) -> String {
        metric.displayValue(remaining: preferences.layout.remaining)
    }

    private var customization: some View {
        VStack(alignment: .leading, spacing: 10) {
            AIUsageDisplayControls(preferences: preferences)
            Text(model.localAPI.status).font(.caption).foregroundStyle(.secondary)
            Toggle("Allow drag reordering", isOn: $preferences.displayAllowReorder)
            ForEach(preferences.effectiveDisplayOrder(for: model.providers), id: \.self) { id in
                if let provider = model.providers.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(provider.displayName, isOn: providerBinding(id))
                            providerMoves(id)
                        }
                        .draggable("provider:\(id)")
                        .dropDestination(for: String.self) { items, _ in return dropProvider(items, target: id) }
                        HStack {
                            Toggle("Show", isOn: visibilityBinding(id))
                            Spacer()
                            Button(selectedProvider == id ? "Close metrics" : "Metrics…") {
                                selectedProvider = selectedProvider == id ? nil : id
                            }
                        }
                        if selectedProvider == id {
                            if let row = model.rows.first(where: { $0.id == id }), !model.metrics(for: row).isEmpty {
                                metricSection(row, onDemand: false)
                                metricSection(row, onDemand: true)
                            } else {
                                Text("Enable the provider and refresh to discover its metrics. Saved customization is retained.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func metricSection(_ row: AIUsageRow, onDemand: Bool) -> some View {
        let metrics = model.metrics(for: row).filter { preferences.layout.onDemand.contains($0.id) == onDemand }
        return VStack(alignment: .leading, spacing: 6) {
            Text(onDemand ? "On Demand" : "Always Visible").font(.subheadline)
            ForEach(metrics) { metric in customizationRow(metric, row: row) }
            if metrics.isEmpty { Text("Drag metrics here").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            guard preferences.displayAllowReorder, let id = items.first,
                  model.metrics(for: row).contains(where: { $0.id == id }) else { return false }
            if onDemand { preferences.layout.onDemand.insert(id) } else { preferences.layout.onDemand.remove(id) }
            preferences.layout.metricOrder[row.id] = model.metrics(for: row).map(\.id).filter { $0 != id } + [id]
            return true
        }
    }

    private func customizationRow(_ metric: AIUsageMetric, row: AIUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.meter.label)
                Spacer()
                Button(preferences.layout.pins[row.id]?.contains(metric.id) == true ? "Unstar" : "Star") {
                    star(metric, row: row)
                }.help("Pin up to two metrics per provider")
                metricMoves(metric.id, row: row)
            }
            HStack {
                Toggle("Enabled", isOn: metricBinding(metric.id, hidden: true))
                Toggle("On demand", isOn: metricBinding(metric.id, hidden: false))
            }
        }
        .font(.caption).padding(.leading, 8)
        .draggable(metric.id)
        .dropDestination(for: String.self) { items, _ in return dropMetric(items, target: metric.id, row: row) }
    }

    private func providerMoves(_ id: String) -> some View {
        let order = preferences.effectiveDisplayOrder(for: model.providers)
        return moveButtons(id, order: order) { source, target in model.moveProvider(source, before: target) }
    }

    private func metricMoves(_ id: String, row: AIUsageRow) -> some View {
        moveButtons(id, order: model.metrics(for: row).map(\.id)) { source, target in
            model.moveMetric(source, before: target, row: row)
        }
    }

    private func moveButtons(_ id: String, order: [String], move: @escaping (String, String) -> Void) -> some View {
        let index = order.firstIndex(of: id) ?? 0
        return Group {
            Button("Move up", systemImage: "arrow.up") {
                if index > 0 { move(id, order[index - 1]) }
            }.disabled(index == 0)
            Button("Move down", systemImage: "arrow.down") {
                if index + 1 < order.count { move(order[index + 1], id) }
            }.disabled(index + 1 >= order.count)
        }
        .labelStyle(.iconOnly)
    }

    private func dropProvider(_ items: [String], target: String) -> Bool {
        guard preferences.displayAllowReorder, let item = items.first,
              item.hasPrefix("provider:"), model.providers.contains(where: { "provider:\($0.id)" == item }) else { return false }
        model.moveProvider(String(item.dropFirst("provider:".count)), before: target)
        return true
    }

    private func dropMetric(_ items: [String], target: String, row: AIUsageRow) -> Bool {
        guard preferences.displayAllowReorder, let id = items.first,
              model.metrics(for: row).contains(where: { $0.id == id }) else { return false }
        model.moveMetric(id, before: target, row: row)
        return true
    }

    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { preferences.isEnabled(id) }, set: { preferences.setEnabled(id, $0) })
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { preferences.displayVisibility[id] != false }, set: { preferences.setVisibility(id, visible: $0) })
    }

    private func metricBinding(_ id: String, hidden: Bool) -> Binding<Bool> {
        Binding(get: { hidden ? !preferences.layout.hidden.contains(id) : preferences.layout.onDemand.contains(id) },
                set: { enabled in
                    if hidden {
                        if enabled { preferences.layout.hidden.remove(id) } else { preferences.layout.hidden.insert(id) }
                    } else {
                        if enabled { preferences.layout.onDemand.insert(id) } else { preferences.layout.onDemand.remove(id) }
                    }
                })
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

/// These are the production bindings, also exercised by interaction tests.
struct AIUsageDisplayControls: View {
    @ObservedObject var preferences: AIUsagePreferences
    var body: some View {
        AIUsageHistoryConsent(preferences: preferences)
        Toggle("Show AI usage in menu bar", isOn: $preferences.menuBarEnabled)
        Toggle("Remaining values (off: used)", isOn: $preferences.layout.remaining)
        Toggle("Exact reset time (off: countdown)", isOn: $preferences.layout.absoluteReset)
        Toggle("Menu-bar mini-bars (off: text)", isOn: $preferences.layout.bars)
        Toggle("Local usage API (port 6737)", isOn: $preferences.localAPIEnabled)
        Text("Off by default. Other local processes can read enabled providers' usage, never credentials. Browser-origin requests are blocked.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

import Foundation
import Observation
import Combine
import SymCockpitCore

struct AIUsageRow: Identifiable, Equatable {
    let providerID: String
    let displayName: String
    let snapshot: AIUsageSnapshot?
    /// Already redacted at the service boundary.
    let error: String?
    let lastSuccessAt: Date?
    let history: [MetricSample]
    var recordedHistory: AIUsageRecordedHistory?
    var id: String { providerID }
    var isUnavailable: Bool { snapshot == nil }
    var isStale: Bool { snapshot != nil && error != nil }
}

struct AIUsagePin: Equatable {
    let label: String
    let value: String
    let fraction: Double?
    let stale: Bool
    var text: String { "\(label) \(value)\(stale ? " (stale)" : "")" }
}

@MainActor
@Observable
final class AIUsageViewModel {
    private(set) var rows: [AIUsageRow] = []
    private(set) var statusItemText = ""
    private(set) var statusPins: [AIUsagePin] = []
    let providers: [any AIUsageProvider]
    let preferences: AIUsagePreferences
    let localAPI = AIUsageAPIHost()
    var onStatusItemTextChanged: (() -> Void)?

    private let fetch: @Sendable (Set<String>, Bool) async -> [AIUsageService.ProviderResult]
    private let fetchEstimatedHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let fetchClaudeHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let fetchHistory: (@Sendable (Set<String>, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let cached: @Sendable (Set<String>) -> [AIUsageService.ProviderResult]
    private var preferenceObserver: AnyCancellable?
    private var historyBuffers: [String: MetricsRingBuffer] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var isRefreshing = false
    private var isStopped = false

    convenience init(controller: TuneController, preferences: AIUsagePreferences) {
        let service = controller.aiUsageService
        self.init(providers: service.providers, preferences: preferences,
            cached: { service.cachedResults(providerIDs: $0) },
            fetchEstimatedHistory: { await service.usageAll(providerIDs: $0, force: $1, grokHistoryEnabled: $2,
                opencodeHistoryEnabled: $3, claudeHistoryEnabled: $4, claudeHistoryOnly: $5,
                codexHistoryEnabled: $6, codexHistoryOnly: $7) },
            fetch: { await service.usageAll(providerIDs: $0, force: $1) })
    }

    init(providers: [any AIUsageProvider], preferences: AIUsagePreferences,
         cached: @escaping @Sendable (Set<String>) -> [AIUsageService.ProviderResult] = { _ in [] },
         fetchEstimatedHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetchClaudeHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetchHistory: (@Sendable (Set<String>, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetch: @escaping @Sendable (Set<String>, Bool) async -> [AIUsageService.ProviderResult]) {
        self.providers = providers
        self.preferences = preferences
        self.cached = cached
        self.fetch = fetch
        self.fetchHistory = fetchHistory
        self.fetchClaudeHistory = fetchClaudeHistory
        self.fetchEstimatedHistory = fetchEstimatedHistory
        preferences.onUsageSelectionChanged = { [weak self] in
            guard let self else { return }
            self.rows.removeAll { !self.preferences.isEnabled($0.id) }
            for index in self.rows.indices where !self.preferences.consentedHistoryProviders.contains(self.rows[index].id) {
                self.rows[index].recordedHistory = nil
            }
            self.updateStatusItem()
            self.refreshNow()
        }
        preferenceObserver = preferences.objectWillChange.sink { [weak self] _ in
            // Published emits before mutation. Read the new preferences on the next main-actor turn.
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }
    }

    var orderedRows: [AIUsageRow] {
        AIUsageLayout.ordered(preferences.effectiveDisplayOrder(for: providers), available: rows.map(\.id))
            .compactMap { id in rows.first { $0.id == id } }
    }

    var visibleRows: [AIUsageRow] {
        orderedRows.filter { row in
            preferences.isEnabled(row.id) && preferences.isVisible(row.id,
                isConfigured: providers.first { $0.id == row.id }?.isConfigured ?? false)
        }
    }

    var localRecordedSpend: AIUsageLocalRecordedSpend {
        AIUsageLocalRecordedSpend(providerIDs: preferences.consentedHistoryProviders,
            histories: Dictionary(rows.compactMap { row in row.recordedHistory.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first }),
            period: preferences.localSpendPeriod, mode: preferences.localSpendMode)
    }

    func metrics(for row: AIUsageRow) -> [AIUsageMetric] {
        let metrics = row.snapshot.map { AIUsageMetric.metrics(snapshot: $0) } ?? []
        let order = AIUsageLayout.ordered(preferences.layout.metricOrder[row.id] ?? [], available: metrics.map(\.id))
        let ordered = order.compactMap { id in metrics.first { $0.id == id } }
        return ordered.filter { !preferences.layout.onDemand.contains($0.id) }
            + ordered.filter { preferences.layout.onDemand.contains($0.id) }
    }

    func moveProvider(_ id: String, before target: String) {
        let order = preferences.effectiveDisplayOrder(for: providers)
        preferences.displayOrder = AIUsageLayout.moving(id, before: target, in: order)
    }

    func moveMetric(_ id: String, before target: String, row: AIUsageRow) {
        let order = metrics(for: row).map(\.id)
        preferences.layout.metricOrder[row.id] = AIUsageLayout.moving(id, before: target, in: order)
        if preferences.layout.onDemand.contains(target) { preferences.layout.onDemand.insert(id) } else {
            preferences.layout.onDemand.remove(id)
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        isStopped = false
        apply(cached(preferences.enabledProviders).map {
            .init(providerID: $0.providerID, snapshot: $0.snapshot, error: $0.error ?? "Cached usage; awaiting refresh")
        }, recordSamples: false)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = max(1, self.preferences.refreshInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        localAPI.stop()
    }

    func refreshNow(providerID: String? = nil) { Task { await refresh(providerID: providerID) } }

    func refresh(providerID: String? = nil, force: Bool = true) async {
        guard !isStopped else { return }
        let enabled = preferences.enabledProviders
        let revision = preferences.enabledRevision
        guard !enabled.isEmpty else {
            rows = []
            updateStatusItem()
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let selected = providerID.map { enabled.intersection([$0]) } ?? enabled
        guard !selected.isEmpty else { return }
        let results: [AIUsageService.ProviderResult]
        if let fetchEstimatedHistory {
            let consent = preferences.consentedHistoryProviders.intersection(selected)
            results = await fetchEstimatedHistory(selected, force, consent.contains("grok"), consent.contains("opencode"),
                consent.contains("claude"), consent.contains("claude") && preferences.claudeHistoryOnly,
                consent.contains("codex"), consent.contains("codex") && preferences.codexHistoryOnly)
        } else if let fetchClaudeHistory {
            let consent = preferences.consentedHistoryProviders.intersection(selected)
            results = await fetchClaudeHistory(selected, force, consent.contains("grok"), consent.contains("opencode"),
                                              consent.contains("claude"), consent.contains("claude") && preferences.claudeHistoryOnly)
        } else if let fetchHistory {
            results = await fetchHistory(selected, force, preferences.consentedHistoryProviders.contains("grok") && selected.contains("grok"),
                                         preferences.consentedHistoryProviders.contains("opencode") && selected.contains("opencode"))
        } else {
            results = await fetch(selected, force)
        }
        guard !isStopped, !Task.isCancelled else { return }
        guard revision == preferences.enabledRevision else {
            rows.removeAll { !preferences.enabledProviders.contains($0.id) }
            updateStatusItem()
            refreshNow()
            return
        }
        let untouched = rows.filter { !selected.contains($0.id) && enabled.contains($0.id) }.map {
            AIUsageService.ProviderResult(providerID: $0.id, snapshot: $0.snapshot, error: $0.error, history: $0.recordedHistory)
        }
        apply(untouched + results.filter { selected.contains($0.providerID) })
    }

    func apply(_ results: [AIUsageService.ProviderResult], recordSamples: Bool = true) {
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        rows = results.compactMap { result in
            let id = result.providerID
            guard seen.insert(id).inserted else { return nil }
            let snapshot = result.snapshot
            if recordSamples, let snapshot, result.error == nil, previous[id]?.snapshot?.fetchedAt != snapshot.fetchedAt {
                recordHistory(id: id, snapshot: snapshot)
            }
            return AIUsageRow(providerID: id,
                displayName: providers.first { $0.id == id }?.displayName ?? id,
                snapshot: snapshot,
                error: AIUsageFormatting.unavailableReason(providerID: id, error: result.error,
                    entryPaths: preferences.entryPaths),
                lastSuccessAt: snapshot?.fetchedAt ?? previous[id]?.lastSuccessAt,
                history: historyBuffers[id]?.samples ?? [],
                recordedHistory: preferences.consentedHistoryProviders.contains(id) ? result.history : nil)
        }
        updateStatusItem()
    }

    private func recordHistory(id: String, snapshot: AIUsageSnapshot) {
        let buffer = historyBuffers[id] ?? MetricsRingBuffer(capacity: 120)
        historyBuffers[id] = buffer
        guard let meter = snapshot.meters.first,
              let fraction = AIUsageFormatting.progressFraction(for: meter) else {
            buffer.recordGap(reason: "no meter", timestamp: snapshot.fetchedAt)
            return
        }
        buffer.recordValue(fraction * 100, timestamp: snapshot.fetchedAt)
    }

    func updateStatusItem() {
        let apiRows = providers.filter { preferences.isEnabled($0.id) }.map { provider in
            let row = rows.first { $0.id == provider.id }
            return AIUsageService.ProviderResult(providerID: provider.id, snapshot: row?.snapshot, error: row?.error)
        }
        localAPI.update(enabled: preferences.localAPIEnabled && !isStopped, rows: apiRows)
        statusPins = preferences.menuBarEnabled ? visibleRows.flatMap { row -> [AIUsagePin] in
            let metrics = metrics(for: row).filter { !preferences.layout.hidden.contains($0.id) }
            let selected = Set((preferences.layout.pins[row.id] ?? []).prefix(2))
            return metrics.filter { selected.contains($0.id) }.compactMap { metric in
                guard let value = metric.value(remaining: preferences.layout.remaining) else { return nil }
                let fraction = metric.fraction(remaining: preferences.layout.remaining)
                guard !preferences.layout.bars || fraction != nil else { return nil }
                return AIUsagePin(label: "\(row.displayName) \(metric.meter.label)", value: value,
                    fraction: fraction, stale: row.isStale)
            }
        } : []
        // Legacy opt-in: with no explicit pins, pin the first readable metric only.
        if statusPins.isEmpty, preferences.menuBarEnabled, preferences.displayPinnedProvider,
           preferences.layout.pins.isEmpty,
           let row = visibleRows.first,
           let metric = metrics(for: row).first(where: { !preferences.layout.hidden.contains($0.id) }),
           let value = metric.value(remaining: preferences.layout.remaining),
           !preferences.layout.bars || metric.fraction(remaining: preferences.layout.remaining) != nil {
            statusPins = [AIUsagePin(label: "\(row.displayName) \(metric.meter.label)", value: value,
                fraction: metric.fraction(remaining: preferences.layout.remaining), stale: row.isStale)]
        }
        if preferences.layout.bars { statusPins = Array(statusPins.prefix(4)) }
        statusItemText = statusPins.map(\.text).joined(separator: " · ")
        onStatusItemTextChanged?()
    }
}

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
    /// Privacy Mode is on and the screen is being captured: no usage values are shown (#451).
    private(set) var isConcealing = false
    /// Injected so tests can fake a capture; the live probe asks the window server.
    var isScreenCaptured: @MainActor () -> Bool = { ScreenCaptureProbe.isScreenCaptured() }
    private var captureTask: Task<Void, Never>?
    /// Urgent limits that did not fit the priority strip (#450).
    private(set) var statusOverflow = 0
    private var quotaAlerts = AIUsageQuotaAlerts()
    private var askedNotificationPermission = false
    /// Injected so tests see the alerts; the live one posts a macOS notification.
    var postAlert: @MainActor (_ title: String, _ body: String) -> Void = { AIUsageNotifier.post(title: $0, body: $1) }
    var requestNotificationPermission: @MainActor () -> Void = { AIUsageNotifier.requestPermission() }
    let providers: [any AIUsageProvider]
    let preferences: AIUsagePreferences
    let localAPI = AIUsageAPIHost()
    var onStatusItemTextChanged: (() -> Void)?

    private let fetch: @Sendable (Set<String>, Bool) async -> [AIUsageService.ProviderResult]
    private let fetchEstimatedHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let fetchClaudeHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let fetchHistory: (@Sendable (Set<String>, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])?
    private let cached: @Sendable (Set<String>) -> [AIUsageService.ProviderResult]
    private let purge: @Sendable (Set<String>) -> Void
    private var preferenceObserver: AnyCancellable?
    private var historyBuffers: [String: MetricsRingBuffer] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var isRefreshing = false
    private var queuedProviders: Set<String> = []
    private var isStopped = false
    /// With the agent every usage read waits behind the others (a slow provider
    /// can take 30 s), so the app fetches only while a surface needs it: the
    /// panel is open or the usage is part of the menu-bar text. Off by default
    /// so a model built without an agent behaves as before.
    var requiresVisibility = false
    var isVisible = false {
        didSet { if isVisible, !oldValue, requiresVisibility { refreshNow() } }
    }

    /// The usage comes from the agent's `ai-usage`. `providers` is only the
    /// catalog's metadata (names, configuration hints): no credential is read here.
    /// Not available through the agent yet: the recorded-history readers
    /// (consent-based Grok/opencode/Claude/Codex history) and the on-disk snapshot cache.
    convenience init(
        session: AgentSession, preferences: AIUsagePreferences,
        providers: [any AIUsageProvider] = SymBrainUsageProvider.catalog()
    ) {
        self.init(providers: providers, preferences: preferences,
            fetch: { selected, _ in await Self.usage(from: session, selected: selected) })
    }

    /// Asks the agent for the selected providers only (`providers`), so symbrain never
    /// discovers or queries a provider the user did not enable (#394). Nothing selected:
    /// no request at all. Rows outside the selection are still dropped as a second guard.
    nonisolated static func usage(from session: AgentSession, selected: Set<String>) async -> [AIUsageService.ProviderResult] {
        guard !selected.isEmpty else { return [] }
        let providers = AgentJSON.array(selected.sorted().map { .string($0) })
        switch await session.perform("ai-usage", params: ["providers": providers]) {
        case .done(let json):
            guard let all = try? AgentDecoding.decode([AIUsageService.ProviderResult].self, from: json) else {
                return selected.sorted().map { .init(providerID: $0, snapshot: nil, error: "AI usage could not be read from the Cockpit agent.") }
            }
            return all.filter { selected.contains($0.providerID) }
        case .failed(let message, _):
            return selected.sorted().map { .init(providerID: $0, snapshot: nil, error: SecretRedactor.redact(message)) }
        case .needsConfirmation:
            return selected.sorted().map { .init(providerID: $0, snapshot: nil, error: "AI usage needs a confirmation.") }
        }
    }

    init(providers: [any AIUsageProvider], preferences: AIUsagePreferences,
         cached: @escaping @Sendable (Set<String>) -> [AIUsageService.ProviderResult] = { _ in [] },
         purge: @escaping @Sendable (Set<String>) -> Void = { _ in },
         fetchEstimatedHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetchClaudeHistory: (@Sendable (Set<String>, Bool, Bool, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetchHistory: (@Sendable (Set<String>, Bool, Bool, Bool) async -> [AIUsageService.ProviderResult])? = nil,
         fetch: @escaping @Sendable (Set<String>, Bool) async -> [AIUsageService.ProviderResult]) {
        self.providers = providers
        self.preferences = preferences
        self.cached = cached
        self.purge = purge
        self.fetch = fetch
        self.fetchHistory = fetchHistory
        self.fetchClaudeHistory = fetchClaudeHistory
        self.fetchEstimatedHistory = fetchEstimatedHistory
        preferences.onProvidersDisabled = { [weak self] ids in self?.purge(ids) }
        preferences.onUsageSelectionChanged = { [weak self] changed in
            guard let self else { return }
            self.rows.removeAll { !self.preferences.isEnabled($0.id) }
            for index in self.rows.indices where !self.preferences.consentedHistoryProviders.contains(self.rows[index].id) {
                self.rows[index].recordedHistory = nil
            }
            self.updateStatusItem()
            // Only the providers this change touched are fetched again (#449).
            let stale = changed.intersection(self.preferences.enabledProviders)
            if !stale.isEmpty { self.refreshNow(providerIDs: stale) }
        }
        preferenceObserver = preferences.objectWillChange.sink { [weak self] _ in
            // Published emits before mutation. Read the new preferences on the next main-actor turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateCaptureWatch()
                if self.preferences.quotaAlertsEnabled, !self.askedNotificationPermission {
                    self.askedNotificationPermission = true
                    self.requestNotificationPermission()
                }
                self.updateStatusItem()
            }
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
        updateCaptureWatch()
        apply(cached(preferences.enabledProviders).map {
            .init(providerID: $0.providerID, snapshot: $0.snapshot, error: $0.error ?? "Cached usage; awaiting refresh")
        }, recordSamples: false)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.requiresVisibility || self.isVisible || self.preferences.menuBarEnabled {
                    await self.refresh()
                }
                let interval = max(1, self.preferences.refreshInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Watches for a screen capture only while Privacy Mode is on and the model runs.
    /// A short poll; one window-server call per tick.
    func updateCaptureWatch() {
        guard preferences.concealWhileCaptured, !isStopped else {
            captureTask?.cancel()
            captureTask = nil
            checkCapture()
            return
        }
        checkCapture()
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkCapture()
            }
        }
    }

    func checkCapture() {
        let concealing = preferences.concealWhileCaptured && !isStopped && isScreenCaptured()
        guard concealing != isConcealing else { return }
        isConcealing = concealing
        updateStatusItem()
    }

    func stop() {
        isStopped = true
        captureTask?.cancel()
        captureTask = nil
        queuedProviders.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        localAPI.stop()
    }

    func refreshNow(providerID: String? = nil) { Task { await refresh(providerID: providerID) } }

    func refreshNow(providerIDs: Set<String>) { Task { await refresh(providerIDs: providerIDs) } }

    /// Runs the providers queued while another refresh ran, in one request.
    private func startQueuedRefresh() {
        guard !isStopped, !queuedProviders.isEmpty else {
            queuedProviders.removeAll()
            return
        }
        let next = queuedProviders
        queuedProviders.removeAll()
        refreshNow(providerIDs: next)
    }

    func refresh(providerID: String? = nil, force: Bool = true) async {
        await refresh(providerIDs: providerID.map { [$0] }, force: force)
    }

    /// `nil`: every enabled provider. A set: only those of them that are enabled.
    func refresh(providerIDs: Set<String>?, force: Bool = true) async {
        guard !isStopped else { return }
        let enabled = preferences.enabledProviders
        let revision = preferences.enabledRevision
        guard !enabled.isEmpty else {
            rows = []
            updateStatusItem()
            return
        }
        guard !isRefreshing else {
            // A per-provider request (for example "Refresh X") must not vanish
            // while another refresh runs: queue it for when that one finishes.
            // Whole-set requests stay coalesced into the running one.
            if let providerIDs { queuedProviders.formUnion(providerIDs.intersection(enabled)) }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            startQueuedRefresh()
        }
        let selected = providerIDs.map { enabled.intersection($0) } ?? enabled
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
            // The selection changed mid-flight: drop these results and fetch again only
            // the providers they were for that are still enabled; the change itself
            // already queued the providers it touched.
            rows.removeAll { !preferences.enabledProviders.contains($0.id) }
            updateStatusItem()
            queuedProviders.formUnion(selected.intersection(preferences.enabledProviders))
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
        if recordSamples { evaluateQuotaAlerts() }
        updateStatusItem()
    }

    /// The bounded, visible limits of the enabled providers, in display order.
    private func priorityCandidates() -> [(item: AIUsagePriorityItem, row: AIUsageRow, metric: AIUsageMetric)] {
        visibleRows.flatMap { row in
            let pins = Set(preferences.layout.pins[row.id] ?? [])
            return metrics(for: row).filter { !$0.isBalance && !preferences.layout.hidden.contains($0.id) }
                .compactMap { metric in
                    metric.fraction(remaining: false).map { used in
                        (AIUsagePriorityItem(providerID: row.id, metricID: metric.id, usedFraction: used,
                                             resetsAt: metric.meter.resetsAt, pinned: pins.contains(metric.id)), row, metric)
                    }
                }
        }
    }

    /// Fresh results only: the tracker always learns the new state, alerts are posted
    /// only with the setting on. Under Privacy Mode an alert names no values.
    private func evaluateQuotaAlerts() {
        let candidates = priorityCandidates()
        let alerts = quotaAlerts.evaluate(candidates.map(\.item), thresholds: preferences.thresholds)
        guard preferences.quotaAlertsEnabled else { return }
        for alert in alerts {
            guard let match = candidates.first(where: { $0.item.metricID == alert.item.metricID }) else { continue }
            let title = switch alert.severity {
            case .usedUp: "AI limit used up"
            case .critical: "AI limit nearly used up"
            default: "AI limit running low"
            }
            let value = match.metric.displayValue(remaining: preferences.layout.remaining)
            postAlert(title, isConcealing
                ? match.row.displayName
                : "\(match.row.displayName) \(match.metric.meter.label): \(value)")
        }
    }

    private func pin(_ row: AIUsageRow, _ metric: AIUsageMetric) -> AIUsagePin? {
        guard let value = metric.value(remaining: preferences.layout.remaining) else { return nil }
        return AIUsagePin(label: "\(row.displayName) \(metric.meter.label)", value: value,
                          fraction: metric.fraction(remaining: preferences.layout.remaining), stale: row.isStale)
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
        statusOverflow = 0
        if preferences.menuBarEnabled, preferences.priorityMenuBar {
            let candidates = priorityCandidates()
            let strip = AIUsagePriority.strip(candidates.map(\.item), thresholds: preferences.thresholds,
                                              now: Date(), count: preferences.priorityCount)
            statusPins = strip.shown.compactMap { item in
                candidates.first { $0.item.metricID == item.metricID }.flatMap { pin($0.row, $0.metric) }
            }
            statusOverflow = strip.overflow
        }
        if isConcealing {
            statusPins = []
            statusOverflow = 0
        }
        statusItemText = (statusPins.map(\.text) + (statusOverflow > 0 ? ["+\(statusOverflow)"] : []))
            .joined(separator: " · ")
        onStatusItemTextChanged?()
    }
}

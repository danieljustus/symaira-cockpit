import Foundation
import Observation
import SymTuneCore

/// One rendered AI-usage row: a provider's latest snapshot (or error) plus
/// its sparkline history.
struct AIUsageRow: Identifiable, Equatable {
    let providerID: String
    let displayName: String
    let snapshot: AIUsageSnapshot?
    /// Redacted error description (already secret-free at the service).
    let error: String?
    /// When the provider last succeeded — shown with the error state so a
    /// stale value is never mistaken for a fresh zero.
    let lastSuccessAt: Date?
    /// Rolling usage history for the sparkline (primary meter percent).
    let history: [MetricSample]

    var id: String { providerID }

    var isUnavailable: Bool { snapshot == nil }
}

/// Fetches AI usage for the enabled providers and formats it for the
/// popover card, the preferences catalog, and the optional menu-bar readout.
///
/// Only providers the user enabled are fetched — an all-off preference set
/// performs zero network calls. The refresh loop runs at the configured
/// interval (default 5 minutes).
@MainActor
@Observable
final class AIUsageViewModel {
    // MARK: - Published state

    private(set) var rows: [AIUsageRow] = []
    /// Compact menu-bar readout for the primary enabled provider.
    private(set) var statusItemText: String = ""
    /// Provider catalog for preferences — exposes full provider instances
    /// so the UI can render credential inputs and auth state (issue #360).
    let providers: [any AIUsageProvider]

    var onStatusItemTextChanged: (() -> Void)?

    // MARK: - Dependencies

    private let controller: TuneController
    /// Exposed so an embedding host can offer the menu-bar readout switch
    /// next to the metric switches instead of only in Preferences.
    let preferences: AIUsagePreferences

    private var historyBuffers: [String: MetricsRingBuffer] = [:]
    private var lastSuccessAt: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Guards against overlapping fetches — the refresh loop and the card's
    /// refresh button can both fire while a report is still in flight.
    private var isRefreshing = false

    init(controller: TuneController, preferences: AIUsagePreferences) {
        self.controller = controller
        self.preferences = preferences
        self.providers = controller.aiUsageService.providers
    }

    // MARK: - Lifecycle

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.preferences.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// One immediate refresh (also used right after preference changes).
    func refreshNow() {
        Task { await refresh() }
    }

    // MARK: - Fetch

    private func refresh() async {
        let enabled = preferences.enabledProviders
        guard !enabled.isEmpty else {
            rows = []
            updateStatusItem()
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // `usageAll()` is nonisolated and wraps a subprocess that can take
        // seconds, so awaiting it runs the fetch on the cooperative pool and
        // leaves the popover interactive. The old code called the controller's
        // synchronous bridge, which parked the main thread on a semaphore for
        // the whole `symbrain` call.
        let service = controller.aiUsageService
        let report = await service.usageAll()
        let enabledResults = report.filter { enabled.contains($0.providerID) }
        let now = Date()

        var newRows: [AIUsageRow] = []
        for result in enabledResults {
            let id = result.providerID
            let displayName = providers.first { $0.id == id }?.displayName ?? id
            if let snapshot = result.snapshot {
                lastSuccessAt[id] = now
                recordHistory(id: id, snapshot: snapshot, at: now)
            } else {
                if historyBuffers[id] == nil {
                    historyBuffers[id] = MetricsRingBuffer(capacity: 120)
                }
                historyBuffers[id]?.recordGap(reason: "unavailable", timestamp: now)
            }
            newRows.append(AIUsageRow(
                providerID: id,
                displayName: displayName,
                snapshot: result.snapshot,
                error: result.error,
                lastSuccessAt: lastSuccessAt[id],
                history: historyBuffers[id]?.samples ?? []
            ))
        }
        rows = newRows
        updateStatusItem()
    }

    /// Records the primary meter's used fraction (0…1) into the provider's
    /// history buffer for the sparkline.
    private func recordHistory(id: String, snapshot: AIUsageSnapshot, at date: Date) {
        let buffer = historyBuffers[id] ?? {
            let buffer = MetricsRingBuffer(capacity: 120)
            historyBuffers[id] = buffer
            return buffer
        }()
        guard let meter = snapshot.meters.first,
              let fraction = AIUsageFormatting.progressFraction(for: meter)
        else {
            buffer.recordGap(reason: "no meter", timestamp: date)
            return
        }
        buffer.recordValue(fraction * 100, timestamp: date)
    }

    /// The readout follows the first provider that has something to say, not
    /// merely the first that answered: a provider can return a snapshot with
    /// no meters (an unlimited plan, or an account type that exposes none),
    /// and stopping there left the menu bar blank while a later provider had
    /// a perfectly good number.
    private func updateStatusItem() {
        guard preferences.menuBarEnabled else {
            statusItemText = ""
            onStatusItemTextChanged?()
            return
        }
        let text = rows.lazy
            .compactMap { row -> String? in
                guard row.snapshot != nil else { return nil }
                let text = AIUsageFormatting.statusItemText(for: row.snapshot)
                return text == "—" ? nil : text
            }
            .first
        statusItemText = text.map { "AI \($0)" } ?? ""
        onStatusItemTextChanged?()
    }
}

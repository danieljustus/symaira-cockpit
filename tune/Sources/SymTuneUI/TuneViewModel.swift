import Foundation
import Observation
import SymTuneCore

/// Hardware readings gathered off the main thread.
private struct HardwareSnapshot: Sendable {
    let metrics: SystemMetricsReport
    let sensors: SensorReport?
    let battery: BatteryReport?
}

/// Single source of truth for the menu-bar app.
///
/// ## Why this exists
/// The status item and the popover used to poll the hardware independently on
/// two timers, and the popover re-read every sensor on a 3-second timer that
/// blocked the main thread. Both now share one tiered poll:
///
/// - **Every tick**: system metrics (cheap: `sysctl`/`mach` calls only).
/// - **Every tick while the popover is open**: SMC sensors and battery — the
///   expensive IOKit reads, executed **off the main thread**.
/// - **Every eighth tick**: the display list, which changes only when the user
///   plugs a monitor in.
///
/// AppKit-backed reads (displays, brightness, dim, warmth) stay on the main
/// actor because `NSScreen` is not thread-safe; they are also the cheap ones.
///
/// Properties are only reassigned when the value actually changed, so a quiet
/// system produces no SwiftUI invalidation at all.
@MainActor
@Observable
final class TuneViewModel {
    // MARK: - Published state

    private(set) var metrics: SystemMetricsReport?
    private(set) var sensors: SensorReport?
    private(set) var battery: BatteryReport?
    private(set) var displays: [DisplayInfo] = []
    private(set) var metricRows: [MetricRowData] = []
    private(set) var overrides = ActiveOverrides()
    private(set) var keepAwake: KeepAwakeSession = .inactive

    /// Rendered menu-bar text (empty when the icon fallback should be used).
    private(set) var statusItemText: String = ""

    /// The same title as ``statusItemText``, but keeping icon segments intact
    /// so the status item can draw real SF Symbols.
    private(set) var statusItemSegments: [StatusItemSegment] = []

    private(set) var builtinBrightness: Double = 0.5
    private(set) var dimAmount: Double = 0.0
    private(set) var warmth: Double = 0.0

    /// Requested vs. actually-applied extended brightness, so the UI can be
    /// honest about a boost that the display has not granted headroom for.
    private(set) var extendedBrightness = ExtendedBrightnessStatus(
        requested: nil,
        effective: nil,
        mode: nil,
        availableHeadroom: nil,
        isSupported: true
    )

    /// Called whenever ``statusItemText`` changes, so the status item is only
    /// re-laid-out when its content actually differs.
    var onStatusItemTextChanged: (([StatusItemSegment]) -> Void)?

    // MARK: - Dependencies

    private let controller: TuneController
    private let preferences: PreferencesManager

    /// Interval used while the popover is closed. The status item only needs
    /// metrics at a glanceable cadence, so idle cost stays near zero.
    private static let idleInterval: TimeInterval = 10.0

    /// How many ticks between display-list refreshes.
    private static let displayRefreshEveryNTicks = 8

    private var pollTask: Task<Void, Never>?
    private var tick = 0
    private var isRefreshing = false
    /// Bounded number of fast "priming" polls after launch, so a Mac that never
    /// reports CPU utilisation cannot pin the loop at the fast cadence forever.
    private var primingTicksRemaining = 3

    /// Whether the popover (or another detail surface) is on screen. Drives
    /// both the poll interval and whether the expensive tiers run at all.
    private(set) var isDetailVisible = false

    // MARK: - Lifecycle

    init(controller: TuneController, preferences: PreferencesManager) {
        self.controller = controller
        self.preferences = preferences
    }

    func start() {
        restartPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Show/hide the detail surface. Restarts the poll loop so the new cadence
    /// and the expensive tiers take effect immediately rather than after the
    /// current sleep.
    func setDetailVisible(_ visible: Bool) {
        guard isDetailVisible != visible else { return }
        isDetailVisible = visible
        restartPolling()
    }

    /// Force an out-of-band refresh (e.g. right after the user applied a change).
    /// Does not feed the history buffers — only the scheduled tick does, so the
    /// sparklines keep an even sample spacing.
    func refreshNow() {
        Task { await refresh(scheduled: false) }
    }

    /// Insert a sleep/wake gap marker into the sparkline history.
    func recordWakeGap() {
        controller.recordWakeGap()
        rebuildMetricRows()
    }

    // MARK: - Poll loop

    private func currentInterval() -> TimeInterval {
        // CPU utilisation and network rates are deltas: they need a second
        // sample before they read as anything but "unavailable". Poll quickly
        // until that pair exists so the menu bar fills in right after launch
        // instead of showing a partial readout for a whole idle interval.
        if primingTicksRemaining > 0, metrics?.cpu.totalUtilization == nil {
            primingTicksRemaining -= 1
            return TuneConfig.minimumRefreshInterval
        }
        guard isDetailVisible else { return Self.idleInterval }
        return max(preferences.metricsRefreshInterval, TuneConfig.minimumRefreshInterval)
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(scheduled: true)
                let interval = await self.currentInterval()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return // cancelled
                }
            }
        }
    }

    // MARK: - Refresh

    private func refresh(scheduled: Bool) async {
        // A user-triggered refresh can land while the scheduled one is still
        // reading the hardware; letting both through would double-sample the
        // history and read the SMC twice for nothing.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let wantsDetail = isDetailVisible
        let controller = self.controller

        // Expensive, AppKit-free IOKit reads run off the main thread so the UI
        // never stalls on the SMC.
        let snapshot = await Task.detached(priority: .utility) {
            HardwareSnapshot(
                metrics: controller.metricsReport(),
                sensors: wantsDetail ? controller.sensorsReport() : nil,
                battery: wantsDetail ? controller.batteryReport() : nil
            )
        }.value

        // History is fed from exactly one place now. Previously the status item
        // and the popover each called `metricsReport()` on their own timer,
        // which split the deltas between two readers and skewed the CPU and
        // network rates.
        if scheduled {
            controller.recordMetricsHistory(snapshot.metrics)
        }

        if metrics != snapshot.metrics { metrics = snapshot.metrics }
        if let value = snapshot.sensors, sensors != value { sensors = value }
        if let value = snapshot.battery, battery != value { battery = value }

        updateStatusItemText()
        rebuildMetricRows()

        if wantsDetail {
            refreshMainThreadState()
        }

        if scheduled { tick &+= 1 }
    }

    /// Reads that must stay on the main actor (AppKit / overlay state).
    private func refreshMainThreadState() {
        let currentOverrides = controller.activeOverrides()
        if overrides != currentOverrides { overrides = currentOverrides }

        // `activeOverrides()` already read the built-in brightness; reuse it
        // instead of hitting DisplayServices a second time per refresh.
        let brightness = currentOverrides.brightness ?? (try? controller.getBuiltinBrightness())
        if let brightness, builtinBrightness != brightness { builtinBrightness = brightness }

        let dim = 1.0 - controller.getDimLevel()
        if dimAmount != dim { dimAmount = dim }

        let currentWarmth = controller.getWarmthLevel()
        if warmth != currentWarmth { warmth = currentWarmth }

        let extended = controller.extendedBrightnessStatus()
        if extendedBrightness != extended { extendedBrightness = extended }

        let session = controller.keepAwakeSessionStatus()
        if keepAwake != session { keepAwake = session }

        if displays.isEmpty || tick % Self.displayRefreshEveryNTicks == 0 {
            let list = controller.displaysReport().displays
            if displays != list { displays = list }
        }
    }

    // MARK: - Derived state

    private func rebuildMetricRows() {
        let ordered = orderedMetrics(preferences.enabledMetrics)
        guard let report = metrics, !ordered.isEmpty else {
            if !metricRows.isEmpty { metricRows = [] }
            return
        }

        var rows: [MetricRowData] = []
        rows.reserveCapacity(ordered.count)
        for id in ordered {
            let style = preferences.metricStyles[id] ?? .default
            // Only memory needs the total to convert a used-bytes history
            // sample to free bytes; disk's history is already a percentage,
            // whose free share is just the complement.
            let totalBytes: UInt64? = {
                guard id == .memory,
                      let used = report.memory.usedBytes,
                      let free = report.memory.freeBytes else { return nil }
                return used + free
            }()

            guard let stats = controller.metricsHistoryStats(for: id) else {
                guard let fallback = MetricFormatting.fallbackValue(id, report: report, style: style) else { continue }
                rows.append(MetricRowData(
                    id: id,
                    title: id.displayName,
                    current: fallback,
                    minimum: "",
                    maximum: "",
                    samples: []
                ))
                continue
            }
            let formatted = MetricFormatting.historyRowValues(id, stats: stats, style: style, totalBytes: totalBytes)
            rows.append(MetricRowData(
                id: id,
                title: id.displayName,
                current: formatted.current,
                minimum: formatted.minimum,
                maximum: formatted.maximum,
                samples: controller.metricsHistorySamples(for: id)
            ))
        }

        if metricRows != rows { metricRows = rows }
    }

    private func updateStatusItemText() {
        guard let report = metrics else { return }
        let visible = orderedMetrics(preferences.visibleMetrics, fallback: [.cpu, .memory])
        let segments = MetricStyleFormatting.statusItemSegments(
            report: report,
            identifiers: visible,
            styles: preferences.metricStyles
        )
        // Comparing segments, not just the flattened text: two styles can
        // render the same characters with a different icon, and the status
        // item would otherwise keep the stale glyph.
        guard statusItemSegments != segments else { return }
        statusItemSegments = segments
        statusItemText = MetricStyleFormatting.plainText(segments)
        onStatusItemTextChanged?(segments)
    }

    /// The configured display style for one metric, so surfaces outside the
    /// history rows (e.g. the System Status chips) can honour the same
    /// `basis` the menu bar and history card already do, without reaching
    /// into ``PreferencesManager`` directly.
    func metricStyle(for id: MetricIdentifier) -> MetricStyle {
        preferences.metricStyles[id] ?? .default
    }

    private func orderedMetrics(
        _ selected: Set<MetricIdentifier>,
        fallback: [MetricIdentifier] = []
    ) -> [MetricIdentifier] {
        MetricOrdering.ordered(selected, order: preferences.metricOrder, fallback: fallback)
    }

    /// Sync the history buffers after the user changed which metrics are enabled.
    func syncEnabledMetrics() {
        controller.syncEnabledMetrics(preferences.enabledMetrics)
        rebuildMetricRows()
    }
}

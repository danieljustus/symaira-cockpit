import Foundation
import Observation
import SymCockpitCore

/// Single source of truth for the menu-bar app, fed only by the Cockpit agent.
///
/// ## What it does
/// The view model owns no hardware and no logic: it subscribes to the agent's
/// topics, decodes what arrives and keeps it for the views. Presentation state
/// that the views need and the agent does not send lives here: the sparkline
/// ring buffers (filled from received `metrics` samples) and the status-item text.
///
/// ## Subscriptions (Q04: nothing is measured without a view that needs it)
/// - `metrics`: always, because the menu-bar readout (or the HUD) needs it. It
///   runs at the agent's hidden interval (10 s) until a detail surface is open.
/// - `status`, `brightness.get`, `awake.status`, `fan.status`: only while the
///   popover or the cockpit window is on screen. They are unsubscribed when it
///   closes, so a closed panel costs the agent nothing.
///
/// When the agent is not running, every reading is dropped (no stale or made-up
/// value) and ``diagnosis`` says why.
///
/// Properties are only reassigned when the value actually changed, so a quiet
/// system produces no SwiftUI invalidation at all.
@MainActor
@Observable
final class TuneViewModel {
    // MARK: - Published state

    private(set) var metrics: SystemMetricsReport?
    private(set) var storageVolumes: [StorageVolumeReport]?
    private(set) var sensors: SensorReport?
    private(set) var battery: BatteryReport?
    private(set) var displays: [DisplayInfo] = []
    private(set) var metricRows: [MetricRowData] = []
    private(set) var overrides = ActiveOverrides()
    private(set) var keepAwake: KeepAwakeSession = .inactive

    /// Which of the three fan-control positions is selected, and whether a
    /// privileged governor is actually enforcing it. The two are read
    /// separately on purpose: a selection with no governor behind it means
    /// the fans are still on the firmware curve, and the card says so rather
    /// than showing a position that is not in effect.
    private(set) var fanProfile: FanProfile = .system
    private(set) var fanGovernorRunning = false
    /// The raw SMC override and per-fan state from `fan.status`: a selected
    /// `system` profile can still mean fans held at a fixed speed by software.
    private(set) var fanSoftwareOverride = false
    private(set) var fanStates: [FanStatus.FanState] = []
    /// The Cool position's optional maximum average CPU/GPU cluster
    /// temperature, as stored.
    private(set) var fanCoolTarget: Double?
    /// The mean CPU/GPU cluster temperature, for the read-only "now" figure
    /// next to the Cool target.
    private(set) var fanAverageClusterCelsius: Double?

    /// Rendered menu-bar text (empty when the icon fallback should be used).
    private(set) var statusItemText: String = ""

    /// The same title as ``statusItemText``, but keeping icon segments intact
    /// so the status item can draw real SF Symbols.
    private(set) var statusItemSegments: [StatusItemSegment] = []

    private(set) var builtinBrightness: Double = 0.5
    private(set) var dimAmount: Double = 0.0
    private(set) var warmth: Double = 0.0

    /// The agent's state, and the reason the app shows while it is not usable.
    private(set) var agentState: AgentState
    /// An answer that could not be read (the agent broke its own contract).
    private(set) var unreadableAnswer: String?

    var isAgentReady: Bool {
        if case .ready = agentState { return true }
        return false
    }

    var diagnosis: AgentDiagnosis? {
        AgentDiagnosis.of(agentState)
            ?? unreadableAnswer.map { AgentDiagnosis(title: "Cockpit agent sent something unexpected", detail: $0) }
    }

    /// A fan change waiting for the user's approval (the agent only planned it),
    /// why the last one failed, and whether one is in flight. Driven by the
    /// actions in `TuneViewModel+Actions.swift`.
    struct FanFailure: Equatable {
        let message: String
        /// The agent lacked the rights: the fan helper has to be switched on or approved.
        let needsHelper: Bool
    }
    var pendingFanChange: PendingChange?
    var fanFailure: FanFailure?
    var fanBusy = false

    /// The same for the charge limit. The agent has no read for the limit that is
    /// in force, so `chargeLimitThisSession` is only what this app confirmed since it
    /// started: `nil` unknown, `.some(nil)` removed, `.some(80)` set to 80 %.
    var pendingChargeChange: PendingChange?
    var chargeFailure: String?
    var chargeBusy = false
    var chargeLimitThisSession: Int??

    /// The health score and its advice from the agent's `status`.
    struct Health: Equatable {
        let score: Int
        let message: String
        let recommendations: [String]
    }
    private(set) var health: Health?

    /// Called whenever ``statusItemText`` changes, so the status item is only
    /// re-laid-out when its content actually differs.
    var onStatusItemTextChanged: (([StatusItemSegment]) -> Void)?

    // MARK: - Dependencies

    let session: AgentSession
    private let preferences: PreferencesManager
    /// Presentation only: rolling samples of what the agent reported.
    private let history = MetricsHistoryService(capacity: 120)

    private static let detailTopics = ["status", "brightness.get", "awake.status", "fan.status"]
    private static let primingOwner = "tune.priming"
    private static let detailOwner = "tune.detail"

    private var metricsToken: UUID?
    private var metricsIntervalMs: Int?
    private var detailTokens: [UUID] = []
    private var stateToken: UUID?
    private var lastSequence: [String: Int] = [:]
    /// Bounded number of samples after launch during which the views count as
    /// visible, so CPU utilisation (a delta that needs a second sample) shows
    /// up after seconds, not after one hidden interval.
    private var primingSamplesRemaining = 3

    /// Whether the popover (or another detail surface) is on screen.
    private(set) var isDetailVisible = false

    // MARK: - Lifecycle

    init(session: AgentSession, preferences: PreferencesManager) {
        self.session = session
        self.preferences = preferences
        self.agentState = session.state
        history.ensureBuffers(for: preferences.enabledMetrics)
    }

    func start() {
        guard stateToken == nil else { return }
        stateToken = session.addStateObserver { [weak self] state in
            Task { @MainActor in self?.agentStateChanged(state) }
        }
        agentState = session.state
        session.setVisible(true, owner: Self.primingOwner)
        subscribeMetrics()
    }

    func stop() {
        if let stateToken { session.removeStateObserver(stateToken) }
        stateToken = nil
        if let metricsToken { session.unsubscribe(metricsToken) }
        metricsToken = nil
        unsubscribeDetail()
        session.setVisible(false, owner: Self.primingOwner)
        session.setVisible(false, owner: Self.detailOwner)
    }

    /// Manual restart of the agent after a failure; the subscriptions come back with it.
    func restartAgent() {
        Task { await session.restart() }
    }

    /// Show/hide the detail surface: its topics are subscribed only while it is on screen.
    func setDetailVisible(_ visible: Bool) {
        guard isDetailVisible != visible else { return }
        isDetailVisible = visible
        if visible {
            subscribeMetrics() // picks up a changed refresh interval
            subscribeDetail()
        } else {
            unsubscribeDetail()
        }
        session.setVisible(visible, owner: Self.detailOwner)
    }

    /// Force an out-of-band read (e.g. right after the user applied a change).
    /// Does not feed the history buffers — only samples do, so the sparklines
    /// keep an even spacing.
    func refreshNow() {
        Task { await refresh() }
    }

    /// Insert a sleep/wake gap marker into the sparkline history.
    func recordWakeGap() {
        history.recordWakeGap()
        rebuildMetricRows()
    }

    // MARK: - Subscriptions

    private func subscribeMetrics() {
        let interval = max(Int(preferences.metricsRefreshInterval * 1000), Int(TuneConfig.minimumRefreshInterval * 1000))
        if metricsToken != nil, metricsIntervalMs == interval { return }
        if let metricsToken { session.unsubscribe(metricsToken) }
        metricsIntervalMs = interval
        metricsToken = subscription("metrics", visibleMs: interval)
    }

    private func subscribeDetail() {
        let interval = max(Int(preferences.metricsRefreshInterval * 1000), Int(TuneConfig.minimumRefreshInterval * 1000))
        detailTokens = Self.detailTopics.map { subscription($0, visibleMs: interval) }
    }

    private func unsubscribeDetail() {
        detailTokens.forEach(session.unsubscribe)
        detailTokens = []
    }

    private func subscription(_ command: String, visibleMs: Int) -> UUID {
        lastSequence[command] = 0
        return session.subscribe(command, visibleMs: visibleMs) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
    }

    // MARK: - Receiving

    private func agentStateChanged(_ state: AgentState) {
        agentState = state
        lastSequence = lastSequence.mapValues { _ in 0 }
        guard case .ready = state else {
            clearReadings()
            return
        }
        unreadableAnswer = nil
    }

    private func receive(_ event: AgentEvent) {
        // A later sample may already be here when an older one is handled.
        if event.sequence > 0 {
            guard event.sequence > (lastSequence[event.command] ?? 0) else { return }
            lastSequence[event.command] = event.sequence
        }
        switch event.payload {
        case .result(let json):
            apply(event.command, json, scheduled: true)
        case .error(let error):
            // A capability this Mac lacks ends the subscription and shows as
            // "not available"; anything else is a failed sample, not a value.
            if error.exitClass != "unsupported" { reading(event.command, failed: error.message) }
        }
    }

    private func refresh() async {
        guard isAgentReady else { return }
        let commands = ["metrics"] + (isDetailVisible ? Self.detailTopics : [])
        for command in commands {
            if case .done(let json) = await session.perform(command) {
                apply(command, json, scheduled: false)
            }
        }
    }

    private func apply(_ command: String, _ json: AgentJSON, scheduled: Bool) {
        do {
            switch command {
            case "metrics":
                let report = try AgentDecoding.decode(SystemMetricsReport.self, from: json)
                if scheduled { history.record(report) }
                if metrics != report { metrics = report }
                if storageVolumes != report.volumes { storageVolumes = report.volumes }
                updateStatusItemText()
                rebuildMetricRows()
                if scheduled { endPrimingIfDone(report) }
            case "status":
                let report = try AgentDecoding.decode(StatusReport.self, from: json)
                set(\.health, Health(
                    score: report.healthScore, message: report.healthScoreMsg, recommendations: report.recommendations
                ))
                set(\.sensors, report.sensors)
                set(\.battery, report.battery)
                set(\.displays, report.displays.displays)
                set(\.overrides, report.activeOverrides)
                set(\.dimAmount, 1.0 - (report.activeOverrides.dim ?? 1.0))
                set(\.warmth, report.activeOverrides.warmth ?? 0.0)
            case "brightness.get":
                set(\.builtinBrightness, try AgentDecoding.decode(BrightnessReadback.self, from: json).brightness)
            case "awake.status":
                set(\.keepAwake, try AgentDecoding.decode(KeepAwakeSession.self, from: json))
            case "fan.status":
                let status = try AgentDecoding.decode(FanStatus.self, from: json)
                set(\.fanProfile, status.profile)
                set(\.fanGovernorRunning, status.governorRunning)
                set(\.fanCoolTarget, status.coolTargetCelsius)
                set(\.fanAverageClusterCelsius, status.averageClusterCelsius)
                if fanSoftwareOverride != status.softwareOverride { fanSoftwareOverride = status.softwareOverride }
                if fanStates != status.fans { fanStates = status.fans }
            default:
                return
            }
            if unreadableAnswer != nil { unreadableAnswer = nil }
        } catch {
            reading(command, failed: "the answer to \(command) could not be read: \(error.localizedDescription)")
        }
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TuneViewModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func reading(_ command: String, failed message: String) {
        unreadableAnswer = "\(command): \(message)"
    }

    /// The agent is gone: show nothing rather than the last values.
    private func clearReadings() {
        metrics = nil
        storageVolumes = nil
        health = nil
        // An agent that went away knows none of its old plans, and no limit it applied.
        pendingFanChange = nil
        pendingChargeChange = nil
        chargeLimitThisSession = nil
        sensors = nil
        battery = nil
        displays = []
        overrides = ActiveOverrides()
        keepAwake = .inactive
        fanProfile = .system
        fanGovernorRunning = false
        fanSoftwareOverride = false
        fanStates = []
        fanCoolTarget = nil
        fanAverageClusterCelsius = nil
        metricRows = []
        updateStatusItemText()
    }

    private func endPrimingIfDone(_ report: SystemMetricsReport) {
        guard primingSamplesRemaining > 0 else { return }
        primingSamplesRemaining -= 1
        if report.cpu.totalUtilization != nil || primingSamplesRemaining == 0 {
            primingSamplesRemaining = 0
            session.setVisible(false, owner: Self.primingOwner)
        }
    }

    // MARK: - Derived state

    /// Whether this Mac reports any fan. `nil` sensors means "not read yet", and an
    /// unsupported SMC connection means "unknown, not measured": both count as
    /// present, so the fan controls do not vanish just because the read that would
    /// confirm them is itself blocked. Only a successful read of zero fans says no.
    var hasFans: Bool {
        guard let sensors, sensors.smcSupported else { return true }
        return !sensors.fans.isEmpty
    }

    /// What "Brighter" is really doing when the display grants less than asked.
    var extendedBrightnessNote: String? {
        guard let requested = overrides.edrBrightness else { return nil }
        let builtin = displays.first { $0.isBuiltin == true } ?? displays.first
        guard let headroom = builtin?.maxEDRHeadroom, requested > headroom + 0.01 else { return nil }
        let available = max(0, Int(((headroom - 1.0) * 100).rounded()))
        return available == 0
            ? "No HDR headroom right now — turn on High Dynamic Range for this display in System Settings › Displays for the full range."
            : "Limited to +\(available)% — that is all the headroom this display grants."
    }

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
            // Both byte metrics need a total, for different reasons: memory
            // stores used bytes and needs used + free to derive the free side
            // and the percentage; disk stores a percentage and needs the
            // volume capacity to derive gigabytes.
            let totalBytes: UInt64? = {
                switch id {
                case .memory:
                    guard let used = report.memory.usedBytes,
                          let free = report.memory.freeBytes else { return nil }
                    return used + free
                case .disk:
                    return report.disk?.capacityBytes
                default:
                    return nil
                }
            }()

            guard let stats = history.stats(for: id) else {
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
                samples: history.samples(for: id)
            ))
        }

        if metricRows != rows { metricRows = rows }
    }

    private func updateStatusItemText() {
        let visible = orderedMetrics(preferences.visibleMetrics, fallback: [.cpu, .memory])
        let segments = metrics.map {
            MetricStyleFormatting.statusItemSegments(
                report: $0,
                identifiers: visible,
                styles: preferences.metricStyles
            )
        } ?? []
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
        history.ensureBuffers(for: preferences.enabledMetrics)
        rebuildMetricRows()
    }
}

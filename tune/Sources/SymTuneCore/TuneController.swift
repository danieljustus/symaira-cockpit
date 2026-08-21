import Foundation

/// Facade over the individual services. Both the CLI and the MCP server talk to
/// the controller only — they never touch services directly. This is also where
/// the safety policy and restore-on-exit bookkeeping live.
public final class TuneController: Sendable {
    private let smc: SMCService
    private let sensors: SensorService
    private let battery: BatteryService
    private let displays = DisplayService()
    private let power = PowerService()
    private let dimOverlay = DimOverlay()
    private let edrOverlay = EDROverlayService()
    private let displayWrite: any DisplayWriteServiceProtocol
    private let profiles: ProfileService
    public let config: TuneConfig
    private let restoreTracker: OverrideTracker
    private let fanControl: FanControlService
    private let chargeLimit: ChargeLimitService
    private let smcRestoreTracker: SMCRestoreTracker
    private let keepAwakeCoordinator: KeepAwakeCoordinator
    private let metricsService: SystemMetricsService
    private let processUsage: ProcessUsageService
    public let metricsHistory: MetricsHistoryService

    public let dataDir: URL
    private let historyService: HistoryService
    private let powerLock = NSLock()
    nonisolated(unsafe) private var activeTokensCount = 0

    /// The charge limit this process applied; status cross-checks it against
    /// the live SMC inhibit state instead of trusting tracked state alone.
    private let chargeLimitState = ChargeLimitState()

    /// IOKit wake observer used by long-lived processes without an
    /// NSWorkspace notification center; reconciles the charge limit on wake.
    nonisolated(unsafe) private var wakeMonitor: PowerWakeMonitor?

    /// Aggregates AI-usage providers (OpenRouter, …) into one report.
    public let aiUsageService: AIUsageService

    public init(
        config: TuneConfig = TuneConfig(),
        displayWrite: (any DisplayWriteServiceProtocol)? = nil,
        smcService: SMCService? = nil,
        batterySource: (any BatterySource)? = nil,
        dataDir: URL? = nil,
        keepAwakeSource: (any PowerAssertionSource)? = nil,
        metricsSource: (any SystemMetricsSource)? = nil,
        aiUsageProviders: [any AIUsageProvider]? = nil,
        processSource: (any ProcessSampleSource)? = nil
    ) {
        self.config = config
        self.displayWrite = displayWrite ?? HardwareDisplayWriteService(
            displayService: displays,
            edrOverlay: edrOverlay
        )
        let resolvedDataDir = dataDir ?? ConfigPaths().dataDir
        self.dataDir = resolvedDataDir
        self.profiles = ProfileService(dataDir: resolvedDataDir)
        self.historyService = HistoryService(dataDir: resolvedDataDir)
        let smc = smcService ?? SMCService()
        self.smc = smc
        self.sensors = SensorService(smc: smc)
        self.fanControl = FanControlService(smc: smc, sensors: sensors)
        self.chargeLimit = ChargeLimitService(smc: smc)
        self.battery = BatteryService(
            source: batterySource ?? HardwareBatterySource(),
            // The system_profiler read is cached (TTL), so it never lands on a hot
            // loop. Injected battery sources (test seams) get no provider, keeping
            // unit tests free of subprocess calls.
            isChargeLimitSupported: { [chargeLimit] in chargeLimit.detectKeyFamily() != nil },
            appleHealthProvider: batterySource == nil ? SystemProfilerBatteryHealthProvider.shared : nil
        )
        self.smcRestoreTracker = SMCRestoreTracker(
            smc: smc,
            fanControl: fanControl,
            chargeLimit: chargeLimit,
            dataDir: resolvedDataDir
        )
        // Consume a restore record left by a previous process that was killed
        // before it could restore (SIGKILL, panic, forced power-off). This runs
        // before any new override can be applied.
        smcRestoreTracker.consumePersistedRestore()
        self.keepAwakeCoordinator = KeepAwakeCoordinator(source: keepAwakeSource ?? HardwarePowerAssertionSource())
        self.metricsService = SystemMetricsService(source: metricsSource ?? HardwareSystemMetricsSource(smc: smc))
        self.processUsage = ProcessUsageService(source: processSource ?? LibprocProcessSampleSource())
        self.metricsHistory = MetricsHistoryService(capacity: 120)
        // Sync enabled metrics from config into the history buffers
        metricsHistory.ensureBuffers(for: config.enabledMetrics)
        self.aiUsageService = AIUsageService(
            providers: aiUsageProviders ?? Self.defaultAIUsageProviders()
        )
        self.restoreTracker = OverrideTracker(
            displayService: displays,
            edrOverlay: edrOverlay,
            onRestore: { [smcRestoreTracker] in smcRestoreTracker.restoreAll() }
        )
        restoreTracker.registerSignalHandlers()
    }

    deinit {
        keepAwakeCoordinator.end()
        restoreTracker.restoreAll()
        smcRestoreTracker.restoreAll()
        dimOverlay.removeAllOverlays()
        edrOverlay.removeAllOverlays()
    }

    // MARK: - History log helper

    private func logHistory(
        action: String,
        requested: Double? = nil,
        clamped: Double? = nil,
        applied: Double? = nil,
        result: String,
        error: Error? = nil
    ) {
        let reason = error != nil ? SecretRedactor.redact("\(error!)") : nil
        let event = HistoryEvent(
            timestamp: Date(),
            action: action,
            requestedValue: requested,
            clampedValue: clamped,
            appliedValue: applied,
            result: result,
            errorReason: reason
        )
        historyService.logEvent(event)
    }

    // MARK: - Reads

    // MARK: - Metrics History (delegates to MetricsHistoryService)

    public func metricsReport() -> SystemMetricsReport { metricsService.read() }

    /// The processes currently using the most CPU or memory.
    ///
    /// CPU is a rate, so it is differenced against the previous call on this
    /// controller: the first call after launch (or after
    /// ``resetProcessBaseline()``) ranks by memory and reports no CPU figures.
    public func topProcesses(
        sortedBy: ProcessSortKey = .cpu,
        limit: Int = ProcessUsageService.defaultLimit
    ) -> ProcessUsageReport {
        processUsage.report(sortedBy: sortedBy, limit: limit)
    }

    /// Drop the CPU baseline so the next ``topProcesses(sortedBy:limit:)`` call
    /// starts fresh instead of averaging across an idle gap.
    public func resetProcessBaseline() { processUsage.resetBaseline() }

    /// Aggregate AI-usage snapshot across all configured providers.
    ///
    /// Synchronous bridge over the async service: the service bounds every
    /// provider fetch with its own timeout, so this call is guaranteed to
    /// return within (providerTimeout × depth) — never hangs the CLI/MCP.
    public func aiUsageReport() -> [AIUsageService.ProviderResult] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var results: [AIUsageService.ProviderResult] = []
        Task {
            results = await aiUsageService.usageAll()
            semaphore.signal()
        }
        semaphore.wait()
        return results
    }

    /// Known AI usage providers as (id, displayName) pairs — the catalog the
    /// UI uses for per-provider toggles and labels.
    public var aiUsageProviderCatalog: [(id: String, displayName: String)] {
        aiUsageService.providerCatalog
    }

    /// Drop cached AI-usage snapshots so the next report re-reads credentials
    /// and refetches (issue #324). Called when a credential was saved or
    /// cleared so a stale snapshot can't be served for the new state.
    public func resetAIUsageCache() {
        aiUsageService.resetCache()
    }

    /// Persist the latest metric snapshot into the bounded ring buffers. Disabled
    /// metrics receive no samples. If any enabled metric is unavailable in the
    /// report, a gap marker is inserted so renderers produce a visible break
    /// instead of an interpolated stretch across sleep.
    public func recordMetricsHistory(_ report: SystemMetricsReport) { metricsHistory.record(report) }

    /// Insert a gap marker into every active buffer after wake from sleep, producing
    /// a visible break instead of an interpolated stretch across sleep.
    public func recordWakeGap() { metricsHistory.recordWakeGap() }

    /// Synchronise the history buffers with a new set of enabled metrics.
    /// Disabled metrics have their buffers dropped immediately.
    public func syncEnabledMetrics(_ enabled: Set<MetricIdentifier>) { metricsHistory.ensureBuffers(for: enabled) }

    /// Snapshot of sample history for one metric.
    public func metricsHistorySamples(for id: MetricIdentifier) -> [MetricSample] { metricsHistory.samples(for: id) }

    /// Current, min, and max for one metric, or `nil` if no value samples exist.
    public func metricsHistoryStats(for id: MetricIdentifier) -> MetricStats? { metricsHistory.stats(for: id) }

    public func batteryReport() -> BatteryReport { battery.read() }

    public func displaysReport() -> DisplaysReport { displays.list() }

    // MARK: - Keep awake

    public func beginKeepAwake(reason: String, preventDisplaySleep: Bool) throws -> KeepAwakeToken {
        let token = try power.begin(reason: reason, preventDisplaySleep: preventDisplaySleep)
        powerLock.lock()
        activeTokensCount += 1
        powerLock.unlock()
        return token
    }

    public func endKeepAwake(_ token: KeepAwakeToken) {
        power.end(token)
        powerLock.lock()
        activeTokensCount = max(0, activeTokensCount - 1)
        powerLock.unlock()
    }

    public func isKeepAwakeActive() -> Bool {
        powerLock.lock()
        defer { powerLock.unlock() }
        return activeTokensCount > 0
    }

    // MARK: - Keep-awake sessions (high-level coordinator)

    /// Begin a session-level keep-awake period.  At most one session is active;
    /// calling `beginKeepAwakeSession` again while a session is running returns
    /// the current session unchanged.
    @discardableResult
    public func beginKeepAwakeSession(
        duration: TimeInterval?,
        preventDisplaySleep: Bool = false,
        reason: String = "symtune keep-awake session"
    ) throws -> KeepAwakeSession {
        try keepAwakeCoordinator.begin(
            duration: duration,
            preventDisplaySleep: preventDisplaySleep,
            reason: reason
        )
    }

    /// End the current keep-awake session.  Idempotent.
    public func endKeepAwakeSession() {
        keepAwakeCoordinator.end()
    }

    /// Return a snapshot of the current keep-awake session.
    public func keepAwakeSessionStatus() -> KeepAwakeSession {
        keepAwakeCoordinator.status()
    }

    // MARK: - Status Snapshot & Active Overrides

    public func activeOverrides() -> ActiveOverrides {
        let charge = activeChargeLimit()
        return ActiveOverrides(
            brightness: restoreTracker.hasBrightnessOverride() ? (try? getBuiltinBrightness()) : nil,
            dim: getDimLevel() < 1.0 ? getDimLevel() : nil,
            warmth: getWarmthLevel() > 0.0 ? getWarmthLevel() : nil,
            edrBrightness: restoreTracker.hasEDROverride() ? restoreTracker.appliedEDRBrightness : nil,
            fanFraction: activeFanFraction(),
            chargeLimitPercent: charge.percent,
            chargeLimitState: charge.state
        )
    }

    private func activeFanFraction() -> Double? {
        // Best-effort: read current fan targets and report the uniform fraction.
        guard smc.isAvailable else { return nil }
        let fanCount = smc.readKeyUInt("FNum").map { Int($0) } ?? 0
        guard fanCount > 0 else { return nil }
        var fractions: [Double] = []
        for i in 0..<fanCount {
            guard let mode = smc.readFanMode(fanIndex: i), mode == 1 else { return nil }
            guard let target = smc.readFanTargetRPM(fanIndex: i),
                  let max = smc.readFanMaxRPM(fanIndex: i), max > 0 else { return nil }
            fractions.append(target / max)
        }
        let avg = fractions.reduce(0, +) / Double(fractions.count)
        return avg
    }

    public func statusReport() -> StatusReport {
        let sensorsRep = sensorsReport()
        let batteryRep = batteryReport()
        let displaysRep = displaysReport()
        let overrides = activeOverrides()
        let keepAwake = isKeepAwakeActive()

        let result = HealthScorer.calculateScore(
            sensors: sensorsRep,
            battery: batteryRep,
            activeOverrides: overrides,
            isKeepAwakeActive: keepAwake
        )

        return StatusReport(
            healthScore: result.score,
            healthScoreMsg: result.message,
            recommendations: result.recommendations,
            activeOverrides: overrides,
            sensors: sensorsRep,
            battery: batteryRep,
            displays: displaysRep
        )
    }

    // MARK: - Write surface (v0.2 core)

    public func getBuiltinBrightness() throws -> Double {
        try displayWrite.getBuiltinBrightness()
    }

    public func applyBuiltinBrightness(_ value: Double) throws {
        let clamped = SafetyPolicy.clamp(value, config.brightnessMin, config.brightnessMax)
        do {
            let original = try? displayWrite.getBuiltinBrightness()
            if let original { restoreTracker.saveBrightness(Float(original)) }
            try displayWrite.setBuiltinBrightness(Float(clamped))
            logHistory(action: "brightness.set", requested: value, clamped: clamped, applied: clamped, result: "success")
        } catch {
            logHistory(action: "brightness.set", requested: value, clamped: clamped, applied: nil, result: "failed", error: error)
            throw error
        }
    }

    public func applyExtendedBrightness(_ value: Double) throws {
        let clamped = SafetyPolicy.clamp(value, config.extendedBrightnessMin, config.extendedBrightnessMax)
        do {
            restoreTracker.saveOriginalEDRHeadroom(edrOverlay)
            restoreTracker.saveEDRBrightness(clamped)
            try displayWrite.applyExtendedBrightness(clamped, displayID: nil)
            logHistory(action: "extbright.set", requested: value, clamped: clamped, applied: clamped, result: "success")
        } catch {
            logHistory(action: "extbright.set", requested: value, clamped: clamped, applied: nil, result: "failed", error: error)
            throw error
        }
    }

    /// What extended brightness is actually doing right now.
    ///
    /// Requested and effective are two different things: the display has to
    /// engage EDR before a boost can be written, and the boost is clamped to
    /// the headroom the panel granted. The UI reports this rather than assuming
    /// the requested value took effect.
    public func extendedBrightnessStatus() -> ExtendedBrightnessStatus {
        guard let displayID = DisplayHelpers.builtinDisplayIDOrNil() else {
            return ExtendedBrightnessStatus(
                requested: nil,
                effective: nil,
                availableHeadroom: nil,
                isSupported: false
            )
        }
        return ExtendedBrightnessStatus(
            requested: edrOverlay.currentHeadroom(for: displayID),
            effective: edrOverlay.engagedBrightness(for: displayID),
            mode: edrOverlay.brightnessMode(for: displayID),
            availableHeadroom: edrOverlay.systemEDRHeadroom(for: displayID),
            isSupported: displays.anyEDRCapable()
        )
    }

    /// Re-apply display overrides the system dropped behind our back.
    ///
    /// macOS resets the gamma table on sleep/wake and on display
    /// reconfiguration, which silently cancels an active brightness boost or
    /// warmth shift. Called from the app's wake handler.
    public func reassertDisplayOverrides() {
        edrOverlay.reassert()
        DisplayGammaController.shared.reassert()
    }

    public func applyDim(_ value: Double) throws {
        let clamped = SafetyPolicy.clamp(value, config.dimMin, config.dimMax)
        dimOverlay.applyDim(Float(clamped))
        logHistory(action: "dim.set", requested: value, clamped: clamped, applied: clamped, result: "success")
    }

    public func resetDim() {
        dimOverlay.removeAllOverlays()
        logHistory(action: "dim.reset", result: "success")
    }

    public func getDimLevel() -> Double {
        Double(dimOverlay.dimLevel)
    }

    public func getWarmthLevel() -> Double {
        Double(restoreTracker.currentWarmth)
    }

    public func applyWarmth(_ value: Double) throws {
        let clamped = SafetyPolicy.clamp(value, 0.0, 1.0)
        do {
            restoreTracker.saveWarmth(Float(clamped))
            try displayWrite.applyWarmth(Float(clamped))
            logHistory(action: "warmth.set", requested: value, clamped: clamped, applied: clamped, result: "success")
        } catch {
            logHistory(action: "warmth.set", requested: value, clamped: clamped, applied: nil, result: "failed", error: error)
            throw error
        }
    }

    public func resetWarmth() throws {
        do {
            try displayWrite.resetWarmth()
            // Keep the tracked value in step, or `getWarmthLevel()` (and the
            // popover slider reading it) would keep reporting the old shift.
            restoreTracker.saveWarmth(0)
            logHistory(action: "warmth.reset", result: "success")
        } catch {
            logHistory(action: "warmth.reset", result: "failed", error: error)
            throw error
        }
    }

    public func restoreAll() {
        restoreTracker.restoreAll()
        smcRestoreTracker.restoreAll()
        chargeLimitState.clear()
        logHistory(action: "restore", result: "success")
    }

    // MARK: - Profiles

    public func saveProfile(_ profile: TuneProfile) throws {
        do {
            try profiles.saveProfile(profile)
            logHistory(action: "profile.save", result: "success")
        } catch {
            logHistory(action: "profile.save", result: "failed", error: error)
            throw error
        }
    }

    public func loadProfile(name: String) throws -> TuneProfile {
        try profiles.loadProfile(name: name)
    }

    public func listProfiles() -> [TuneProfile] {
        profiles.listProfiles()
    }

    public func deleteProfile(name: String) throws {
        do {
            try profiles.deleteProfile(name: name)
            logHistory(action: "profile.delete", result: "success")
        } catch {
            logHistory(action: "profile.delete", result: "failed", error: error)
            throw error
        }
    }

    public func applyProfile(_ profile: TuneProfile) throws {
        do {
            if let brightness = profile.brightness {
                try applyBuiltinBrightness(brightness)
            }
            if let dim = profile.dim {
                try applyDim(dim)
            }
            if let warmth = profile.warmth {
                try applyWarmth(warmth)
            }
            logHistory(action: "profile.load", result: "success")
        } catch {
            logHistory(action: "profile.load", result: "failed", error: error)
            throw error
        }
    }

    // MARK: - Rules

    public func saveRules(_ rules: [TuneRule]) throws {
        try profiles.saveRules(rules)
    }

    public func loadRules() -> [TuneRule] {
        profiles.loadRules()
    }

    public func addRule(_ rule: TuneRule) throws {
        try profiles.addRule(rule)
    }

    public func removeRule(id: String) throws {
        try profiles.removeRule(id: id)
    }

    public func getHistory(limit: Int? = 100) -> [HistoryEvent] {
        historyService.readEvents(limit: limit)
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

extension TuneController {
    // MARK: - Reads

    public func sensorsReport() -> SensorReport { sensors.read() }

    /// Deprecated forwarding shim: use ``sensorsReport()``.
    @available(*, deprecated, renamed: "sensorsReport")
    public func sensors_report() -> SensorReport { sensorsReport() }

    public func applyFan(fraction: Double) throws {
        let clamped = SMCWritePolicy.clampFanFraction(fraction, min: config.fanFractionMin, max: config.fanFractionMax)
        do {
            let fanCount = smc.readKeyUInt("FNum").map { Int($0) } ?? 0
            for i in 0..<fanCount {
                smcRestoreTracker.saveFanOriginal(fanIndex: i)
            }
            try fanControl.applyFan(fraction: fraction, config: config)
            logHistory(action: "fan.set", requested: fraction, clamped: clamped, applied: clamped, result: "success")
        } catch let error as FanControlError {
            logHistory(action: "fan.set", requested: fraction, clamped: clamped, applied: nil, result: "failed", error: error)
            throw mapFanControlError(error)
        } catch let error as SMCWritePolicy.ValidationError {
            logHistory(action: "fan.set", requested: fraction, clamped: clamped, applied: nil, result: "failed", error: error)
            throw mapValidationError(error)
        } catch {
            logHistory(action: "fan.set", requested: fraction, clamped: clamped, applied: nil, result: "failed", error: error)
            throw error
        }
    }

    public func restoreFanAuto() throws {
        do {
            try fanControl.restoreAuto()
            logHistory(action: "fan.auto", result: "success")
        } catch let error as FanControlError {
            logHistory(action: "fan.auto", result: "failed", error: error)
            throw mapFanControlError(error)
        } catch {
            logHistory(action: "fan.auto", result: "failed", error: error)
            throw error
        }
    }

    public func applyChargeLimit(percent: Int) throws {
        let clamped = SafetyPolicy.clamp(percent, config.chargeLimitMin, config.chargeLimitMax)
        do {
            try SMCWritePolicy.requireACPower(battery: battery)
            smcRestoreTracker.saveChargeOriginal()
            try chargeLimit.applyChargeLimit(percent: percent, config: config)
            chargeLimitState.set(clamped)
            logHistory(action: "battery-limit.set", requested: Double(percent), clamped: Double(clamped), applied: Double(clamped), result: "success")
        } catch let error as SMCWritePolicy.ValidationError {
            logHistory(action: "battery-limit.set", requested: Double(percent), clamped: Double(clamped), applied: nil, result: "failed", error: error)
            throw mapValidationError(error)
        } catch {
            logHistory(action: "battery-limit.set", requested: Double(percent), clamped: Double(clamped), applied: nil, result: "failed", error: error)
            throw error
        }
    }

    public func clearChargeLimit() throws {
        do {
            try chargeLimit.clearChargeLimit()
            chargeLimitState.clear()
            logHistory(action: "battery-limit.clear", result: "success")
        } catch {
            logHistory(action: "battery-limit.clear", result: "failed", error: error)
            throw error
        }
    }

    private func powerDrawCapability() -> Capability {
        let available = smc.readSystemPower() != nil
        return Capability(
            id: "power.draw.read",
            available: available,
            tier: "core",
            detail: available
                ? "Live DC-in power draw (volts/amps/watts) via SMC keys VD0R/ID0R/PDTR."
                : "SMC DC-in power keys (VD0R/ID0R/PDTR) not exposed on this Mac — live power draw unavailable."
        )
    }

    /// The configured charge limit (the value this process applied) and its
    /// enforcement state, cross-checked against the live SMC. On Apple Silicon
    /// the inhibit bit resets on sleep, so a tracked limit is only reported as
    /// `active` when the hardware still agrees with it.
    private func activeChargeLimit() -> (percent: Int?, state: ChargeLimitEnforcementState?) {
        guard let target = chargeLimitState.percent,
              smc.isAvailable,
              let family = chargeLimit.detectKeyFamily() else {
            return (nil, nil)
        }
        switch family {
        case .chte, .ch0b:
            guard let inhibited = chargeLimit.readInhibitState() else { return (nil, nil) }
            return (target, inhibited ? .active : .lapsed)
        case .chlc:
            guard let hw = smc.readKeyUInt("CHLC").map({ Int($0) }) else { return (nil, nil) }
            return (target, hw == target ? .active : .lapsed)
        }
    }

    // MARK: - Charge-limit reconciliation

    /// Start the IOKit wake monitor (long-lived processes such as `symtune
    /// serve`). The menu-bar app uses `NSWorkspace.didWakeNotification`
    /// instead; both paths end up here. Idempotent.
    public func startWakeMonitoring() {
        if wakeMonitor == nil {
            wakeMonitor = PowerWakeMonitor { [weak self] in
                self?.reconcileChargeLimit()
            }
        }
        wakeMonitor?.start()
    }

    /// Reconcile the configured charge limit against the live battery after a
    /// wake: on Apple Silicon the inhibit bit is volatile and resets on sleep.
    ///
    /// Drives charging between a band instead of a single threshold — inhibit
    /// at/above the target, re-allow only once the battery has dropped
    /// `chargeLimitHysteresisPercent` below it, and keep the current state
    /// while the battery sits inside the band. Intel `CHLC` persists and needs
    /// no re-assertion.
    public func reconcileChargeLimit() {
        #if arch(arm64)
        guard let target = chargeLimitState.percent,
              smc.isAvailable,
              let family = chargeLimit.detectKeyFamily() else { return }
        switch family {
        case .chte, .ch0b:
            guard let percent = batteryReport().currentCapacityPercent else { return }
            let inhibited = chargeLimit.readInhibitState() ?? false
            let hysteresis = config.chargeLimitHysteresisPercent
            if percent >= target {
                if !inhibited {
                    // Lapsed on wake (or never re-applied): re-assert.
                    try? chargeLimit.applyChargeLimit(percent: target, config: config)
                }
            } else if percent <= target - hysteresis, inhibited {
                // Dropped below the band: release the inhibit.
                try? chargeLimit.clearChargeLimit()
            }
        case .chlc:
            break
        }
        #else
        // Intel CHLC persists; nothing to re-assert on wake.
        #endif
    }
}

// MARK: - Capability & permission reporting

extension TuneController {
    public func permissions() -> PermissionStatus {
        let smcWritable = smc.isAvailable
        var notes: [String] = [
            smcWritable
                ? "SMC write access available. Fan and charge-limit writes require root (run with sudo)."
                : "SMC write access unavailable. Fan and charge-limit features require a real Mac and root privileges.",
        ]
        if config.isMCPReadOnly {
            notes.append("MCP server mode is read-only (write tools hidden from tools/list).")
        } else {
            notes.append("MCP server mode is full (all write tools available).")
        }
        return PermissionStatus(
            privilegedHelperInstalled: smcWritable,
            historyWritable: historyService.isWritable,
            mcpMode: config.mcpMode,
            notes: notes
        )
    }

    public func capabilities() -> CapabilityReport {
        let batteryPresent = battery.read().present
        let edrCapable = displays.anyEDRCapable()
        let smcAvailable = sensors.smcAvailable
        let smcWritable = smc.isAvailable

        let caps: [Capability] = [
            Capability(id: "sensors.thermalPressure", available: true, tier: "core",
                       detail: "Coarse thermal pressure from ProcessInfo (nominal…critical)."),
            Capability(id: "sensors.smc", available: smcAvailable, tier: "core",
                       detail: smcAvailable
                           ? "Detailed die temps & fan RPM via AppleSMC IOKit (unprivileged)."
                           : "SMC connection unavailable — detailed sensors not accessible."),
            Capability(id: "battery.read", available: batteryPresent, tier: "core",
                       detail: batteryPresent ? "AppleSmartBattery health readout." : "No battery present."),
            Capability(id: "display.edr.read", available: edrCapable, tier: "core",
                       detail: edrCapable ? "At least one display reports EDR headroom." : "No EDR-capable display detected."),
            Capability(id: "display.brightness.extended.set", available: edrCapable, tier: "core",
                       detail: edrCapable
                            ? "Extended brightness via a 1×1 EDR trigger layer plus a gamma boost, "
                              + "clamped to 1.0–1.6 and to the headroom the display grants."
                            : "No EDR-capable display detected — extended brightness unavailable."),
            Capability(id: "display.dim.set", available: true, tier: "core",
                       detail: "Sub-minimum software dim overlay via transparent NSWindow."),
            Capability(id: "display.brightness.set", available: true, tier: "core",
                       detail: "Built-in display brightness get/set via DisplayServices/IOKit."),
            Capability(id: "display.warmth.set", available: true, tier: "core",
                       detail: "Color temperature warmth as a gamma-LUT shift on the display's own "
                             + "calibration curve, composed with any brightness boost."),
            Capability(id: "processes.read", available: true, tier: "core",
                       detail: "Per-process CPU and memory usage via libproc. Processes owned by "
                             + "other users (root) are not readable without elevation."),
            Capability(id: "power.keepAwake", available: true, tier: "core",
                       detail: "Prevent idle sleep via IOKit power assertion."),
            Capability(id: "fan.control", available: smcWritable, tier: "core",
                       detail: smcWritable
                            ? "Fan speed control via SMC. Requires root for writes."
                            : "SMC unavailable — fan control not possible."),
            Capability(id: "battery.chargeLimit", available: smcWritable, tier: "core",
                       detail: smcWritable
                            ? "Battery charge limiting via SMC. Requires root for writes."
                            : "SMC unavailable — charge limiting not possible."),
            powerDrawCapability(),
        ]

        var recommendations: [String] = []
        if !edrCapable {
            recommendations.append("No EDR-capable display detected; extended brightness will be unavailable here.")
        }
        if !batteryPresent {
            recommendations.append("No battery detected; battery features are not applicable on this Mac.")
        }
        if recommendations.isEmpty {
            recommendations.append("Core features are ready. Run `symtune serve` to expose them over MCP.")
        }

        return CapabilityReport(
            tool: "symtune",
            version: TuneVersion.current,
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            capabilities: caps,
            permissions: permissions(),
            recommendations: recommendations
        )
    }

    // MARK: - AI usage providers

    /// All implemented AI-usage providers (issue #359). Used as the default
    /// when no explicit providers are injected, so the app, CLI, and MCP
    /// server can all report every provider — not just OpenRouter.
    ///
    /// Provider toggles default to off, so registering the full catalog adds
    /// no network calls for users who enable nothing. Each provider resolves
    /// its credentials lazily on access (see the provider doc comments), so
    /// construction cost is bounded.
    public static func defaultAIUsageProviders() -> [any AIUsageProvider] {
        [
            ClaudeUsageProvider(),
            CodexUsageProvider(),
            NousPortalUsageProvider(),
            OpenCodeUsageProvider(),
            CopilotUsageProvider(),
            CursorUsageProvider(),
            KimiUsageProvider(),
            MoonshotUsageProvider(),
            AntigravityUsageProvider(),
            OpenRouterUsageProvider(),
        ]
    }
}

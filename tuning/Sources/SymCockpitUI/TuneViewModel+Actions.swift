import Foundation
import SymCockpitCore

/// Actions of the panel. Each one is a command of the agent's register: a
/// reversible command runs at once, a risky one (the fans) comes back as a
/// plan that the user confirms in the app (`pendingFanChange`) before anything
/// happens. The agent decides the risk class; the app only shows the plan.
extension TuneViewModel {
    /// A recorded plan waiting for the user's approval (and, after it, its result),
    /// with what it will do in words. The confirmation itself is the shared
    /// ``PlanConfirmationModel``, shown by ``PlanConfirmationView``.
    @MainActor
    struct PendingChange {
        let confirmation: PlanConfirmationModel
        let summary: String

        var plan: AgentPlan { confirmation.plan }
        /// True until the plan was sent: the controls it belongs to stay locked while it is open.
        var isOpen: Bool { confirmation.report == nil }
    }

    // MARK: - Reversible commands

    func setBrightness(_ value: Double) async -> ActionOutcome {
        await run("brightness.set", ["value": .number(value)])
    }

    func setWarmth(_ value: Double) async -> ActionOutcome {
        await run("warmth.set", ["value": .number(value)])
    }

    /// Both sides of "Beyond Normal" are written every time: leaving the other
    /// one at its last value would keep it acting after the knob crossed centre.
    func setBeyondNormal(dimFactor: Double, extendedBrightness: Double?) async -> ActionOutcome {
        let dim = await run("dim.set", ["value": .number(dimFactor)], refresh: extendedBrightness == nil)
        guard case .done = dim, let extendedBrightness else { return dim }
        return await run("extbright.set", ["value": .number(extendedBrightness)])
    }

    func setKeepAwake(_ enabled: Bool, preventDisplaySleep: Bool, duration: TimeInterval?) async -> ActionOutcome {
        var params: [String: AgentJSON] = ["enabled": .bool(enabled)]
        if enabled {
            params["prevent_display_sleep"] = .bool(preventDisplaySleep)
            if let duration { params["duration_seconds"] = .number(duration) }
        }
        return await run("awake", params)
    }

    // MARK: - Fans (risky: plan first)

    func requestFanProfile(_ profile: FanProfile) async {
        await requestFan(
            "fan.profile", value: .string(profile.rawValue),
            summary: "Set the fan control to \(profile.displayName)."
        )
    }

    func requestFanCoolTarget(_ celsius: Double?) async {
        let summary = celsius.map { "Cool the Mac at a maximum average of \(Int($0.rounded())) °C." }
            ?? "Turn the Cool temperature target off."
        await requestFan("fan.target", value: celsius.map(AgentJSON.number), summary: summary)
    }

    /// The user approved the pending plan (the shared view calls `confirm` itself;
    /// this is the same step for callers without the view).
    func confirmPendingFanChange() async {
        await pendingFanChange?.confirmation.confirm()
    }

    func cancelPendingFanChange() {
        pendingFanChange = nil
    }

    /// The Done button after the result: the plan is over.
    func dismissPendingFanChange() {
        pendingFanChange = nil
    }

    private func requestFan(_ command: String, value: AgentJSON?, summary: String) async {
        fanFailure = nil
        pendingFanChange = nil
        // The register tells which argument a command takes; an agent without
        // the argument cannot change this yet, and the app says so.
        guard let argument = session.argumentName(of: command) else {
            fanFailure = FanFailure(message: "This Cockpit agent cannot change this fan setting yet.", needsHelper: false)
            return
        }
        fanBusy = true
        defer { fanBusy = false }
        let params: [String: AgentJSON] = [argument: value ?? session.clearValue(of: command)]
        switch await session.perform(command, params: params) {
        case .needsConfirmation(let plan):
            let confirmation = PlanConfirmationModel(plan: plan, session: session)
            confirmation.onFinished = { [weak self, weak confirmation] report in
                guard let self, let confirmation, self.pendingFanChange?.confirmation === confirmation else { return }
                if report.isConfirmed {
                    self.fanFailure = nil
                    self.refreshNow()
                } else {
                    // The failure note below the card keeps the hint for a missing helper approval.
                    self.pendingFanChange = nil
                    self.fanFailure = FanFailure(
                        message: SecretRedactor.redact(report.failureMessage ?? "The fan change was not applied."),
                        needsHelper: report.exitClass == "permission"
                    )
                }
            }
            pendingFanChange = PendingChange(confirmation: confirmation, summary: summary)
        case .done:
            refreshNow()
        case .failed(let message, let exitClass):
            fanFailure = FanFailure(message: SecretRedactor.redact(message), needsHelper: exitClass == "permission")
        }
    }

    // MARK: - Charge limit (risky: plan first)

    /// Asks for a charge limit of `percent` (50 to 100), or removes the limit with `nil`.
    func requestChargeLimit(_ percent: Int?) async {
        chargeFailure = nil
        pendingChargeChange = nil
        let command = percent == nil ? "battery-limit.clear" : "battery-limit.set"
        let params: [String: AgentJSON] = percent.map { ["percent": .number(Double($0))] } ?? [:]
        let summary = percent.map { "Stop charging at \($0) %." } ?? "Remove the charge limit and charge to 100 %."
        chargeBusy = true
        defer { chargeBusy = false }
        switch await session.perform(command, params: params) {
        case .needsConfirmation(let plan):
            let confirmation = PlanConfirmationModel(plan: plan, session: session)
            confirmation.onFinished = { [weak self, weak confirmation] report in
                guard let self, let confirmation, self.pendingChargeChange?.confirmation === confirmation else { return }
                if report.isConfirmed {
                    self.chargeLimitThisSession = .some(percent)
                    self.refreshNow()
                } else {
                    self.pendingChargeChange = nil
                    self.chargeFailure = SecretRedactor.redact(report.failureMessage ?? "The charge limit was not applied.")
                }
            }
            pendingChargeChange = PendingChange(confirmation: confirmation, summary: summary)
        case .done:
            chargeLimitThisSession = .some(percent)
            refreshNow()
        case .failed(let message, _):
            chargeFailure = SecretRedactor.redact(message)
        }
    }

    func dismissPendingChargeChange() {
        pendingChargeChange = nil
    }

    private func run(_ command: String, _ params: [String: AgentJSON], refresh: Bool = true) async -> ActionOutcome {
        let outcome = await session.perform(command, params: params)
        if refresh { refreshNow() }
        return outcome
    }
}

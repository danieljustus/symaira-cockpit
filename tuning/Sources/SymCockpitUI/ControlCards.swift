import SwiftUI
import SymairaTheme
import SymCockpitCore

// MARK: - Display controls

/// Brightness / dim / warmth / extended-brightness sliders.
///
/// Each row owns its drag state (see ``TuneSliderRow``), so moving one slider
/// re-renders that row only — not this card, and not the panel around it.
struct DisplayControlsCard: View {
    let model: TuneViewModel
    /// The user's configured bounds for the Beyond Normal slider (config.toml).
    let config: TuneConfig
    @Environment(\.tunePanelChrome) private var chrome

    /// Who answers the brightness keys, or `nil` in a host that does not offer
    /// the takeover (the standalone Tune app). Issue #250.
    var brightnessKeys: BrightnessKeyPreferences?
    var brightnessKeyController: BrightnessKeyController?

    @State private var displayError: String?

    private var isEDRCapable: Bool {
        model.displays.contains { $0.edrCapable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: chrome == .embedded ? SymairaSpacing.xLarge : SymairaSpacing.small) {
            TuneSliderRow(
                title: "Screen Brightness",
                icon: .lightMode,
                value: model.builtinBrightness,
                range: 0.0...1.0
            ) { value in
                apply { await model.setBrightness(value) }
            }

            if let preferences = brightnessKeys {
                BrightnessKeyRow(preferences: preferences, brightnessKeyController: brightnessKeyController)
            }

            // Software dimming and EDR headroom as one control: centre is the
            // display untouched, and either direction is range symtune adds on
            // top of what the hardware does by itself. See
            // ``BeyondNormalBrightness`` for why the two are folded together
            // and why OS brightness above stays separate.
            CenterAnchoredSliderRow(
                title: "Beyond Normal",
                icon: .appearance,
                position: beyondNormalPosition,
                minimumLabel: "Darker",
                maximumLabel: "Brighter",
                maximumDisabledNote: isEDRCapable ? nil : "Brighter (unsupported)",
                onCommit: applyBeyondNormal
            )

            // Extended brightness depends on the display granting EDR headroom,
            // which it does not always do. Say what is actually happening
            // instead of leaving the slider looking effective.
            if let note = model.extendedBrightnessNote {
                Text(note)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TuneSliderRow(
                title: "Color Warmth",
                icon: .temperature,
                value: model.warmth,
                range: 0.0...1.0
            ) { value in
                apply { await model.setWarmth(value) }
            }

            if let displayError {
                Text(displayError)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.isAgentReady)
        .cardStyle()
    }

    // MARK: - Brightness keys

    /// Who answers F1/F2 — macOS or this app.
    ///
    /// It sits under the brightness slider because it is the same control seen
    /// from the keyboard, and it defaults to the system: taking over a hardware
    /// key is a thing to ask for, never a thing to inherit from an update.
    /// Switching to this app needs an Accessibility grant, so the row explains
    /// the block and offers the way to clear it rather than silently doing
    /// nothing.
    private struct BrightnessKeyRow: View {
        @ObservedObject var preferences: BrightnessKeyPreferences
        var brightnessKeyController: BrightnessKeyController?
        @State private var impediment: BrightnessKeyController.Impediment?

        var body: some View {
            VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                HStack(spacing: SymairaSpacing.medium) {
                    SymairaIconView(.keyboard, size: 14)
                        .frame(width: 18)
                        .foregroundStyle(SymairaTokens.selected)

                    Text("Brightness keys")
                        .symairaText(.body)
                        .foregroundStyle(SymairaTokens.ink)

                    Spacer(minLength: SymairaSpacing.small)
                }

                SymairaSegmentedControl(
                    "Brightness keys",
                    selection: Binding(get: { preferences.handling }, set: { preferences.handling = $0 }),
                    options: [BrightnessKeyHandling.system, .cockpit].map { ($0, $0.displayName) }
                )
                .accessibilityLabel("Brightness keys")
                .help("Who answers F1 and F2 — macOS, or this app with its own HUD")

                if preferences.handling == .cockpit, let impediment {
                    impedimentNote(impediment)
                }
            }
            .onAppear { impediment = brightnessKeyController?.impediment }
            .task(id: preferences.handling) {
                // The controller reaches the grant asynchronously — it keeps
                // retrying while the user is still in System Settings — so the row
                // follows it rather than reading once.
                brightnessKeyController?.onImpedimentChanged = { impediment = $0 }
                impediment = brightnessKeyController?.impediment
            }
        }

        @ViewBuilder
        private func impedimentNote(_ impediment: BrightnessKeyController.Impediment) -> some View {
            switch impediment {
            case .accessibilityNotGranted:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs Accessibility to see the keys before macOS does")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: SymairaSpacing.small) {
                        Button("Grant\u{2026}") {
                            BrightnessKeyController.requestAccessibilityGrant()
                        }
                        Button("Open Settings") {
                            BrightnessKeyController.openAccessibilitySettings()
                        }
                    }
                    .buttonStyle(.link)
                    .symairaText(.caption)
                }
            case .noBuiltInDisplay:
                // External panels are driven over DDC/CI, which this does not do.
                Text("No built-in display to control")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Beyond-normal brightness

    private var beyondNormalPosition: Double {
        BeyondNormalBrightness.position(
            dimFactor: 1.0 - model.dimAmount,
            extendedBrightness: model.overrides.edrBrightness,
            config: config
        )
    }

    private func applyBeyondNormal(_ position: Double) {
        let resolved = BeyondNormalBrightness.resolve(
            position: position,
            config: config,
            allowsExtendedBrightness: isEDRCapable
        )
        apply {
            await model.setBeyondNormal(
                dimFactor: resolved.dimFactor,
                extendedBrightness: isEDRCapable ? resolved.extendedBrightness : nil
            )
        }
    }

    /// Runs a command of the agent; what the agent refused is shown, never swallowed.
    private func apply(_ action: @escaping () async -> ActionOutcome) {
        Task {
            let outcome = await action()
            displayError = outcome.failureMessage.map(SecretRedactor.redact)
        }
    }
}

// MARK: - Fan control

struct FanControlCard: View {
    let model: TuneViewModel
    /// Where a user is sent when fan changes lack the rights to take effect.
    let preferencesManager: PreferencesManager
    let openPreferences: () -> Void

    /// The position the user asked for, drawn while the change is planned or
    /// being applied, so the control follows the click instead of snapping back.
    @State private var requestedProfile: FanProfile?

    private var hasFans: Bool { model.hasFans }

    private var selectedProfile: FanProfile {
        model.pendingFanChange?.isOpen == true || model.fanBusy ? requestedProfile ?? model.fanProfile : model.fanProfile
    }

    var body: some View {
        if hasFans {
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                HStack {
                    Label("Fan Control", symairaIcon: .fan, iconSize: 16)
                        .symairaText(.subheading)
                        .foregroundStyle(SymairaTokens.ink2)
                    Spacer()
                    if let rpm = currentRPM {
                        Text("\(rpm) rpm")
                            .symairaText(.caption)
                            .foregroundStyle(SymairaTokens.ink3)
                    }
                }

                FanProfileSliderRow(
                    profile: selectedProfile,
                    isEnabled: model.isAgentReady && !model.fanBusy && !(model.pendingFanChange?.isOpen ?? false)
                ) { profile in
                    requestedProfile = profile
                    Task { await model.requestFanProfile(profile) }
                }

                Text(selectedProfile.summary)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)

                if selectedProfile == .comfort {
                    FanCoolTargetRow(model: model)
                }

                // The stored profile can say `system` while the SMC still
                // holds a manual override. The agent reports that state; the
                // hand-back is its `fan.auto` command, not local logic here.
                if selectedProfile == .system && model.fanSoftwareOverride {
                    VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                        SymairaNotice(
                            message: "The fans are still held by software. macOS is not controlling them.",
                            tone: .warning
                        )
                        Button("Return fans to macOS") {
                            Task { await model.requestFanAuto() }
                        }
                        .buttonStyle(.link)
                        .symairaText(.caption)
                        .disabled(!model.isAgentReady || model.fanBusy || model.pendingFanChange != nil)
                    }
                    .accessibilityIdentifier("fan-override-warning")
                }

                if let pending = model.pendingFanChange {
                    confirmation(pending)
                } else if model.fanBusy {
                    Text("Applying — you may be asked for your administrator password…")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure = model.fanFailure {
                    failureNote(failure)
                } else if model.fanProfile != .system && !model.fanGovernorRunning {
                    // Honest reporting: a selected position with nothing
                    // enforcing it means the fans are still on the firmware
                    // curve, and saying "Cool" would be a lie.
                    Text("Not in effect — no fan governor is running.")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cardStyle()
        } else {
            VStack(spacing: 6) {
                HStack {
                    Label("Fan Control", symairaIcon: .fan, iconSize: 16)
                        .symairaText(.subheading)
                        .foregroundStyle(SymairaTokens.ink2)
                    Spacer()
                }
                Text("Not available on this Mac")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            }
            .cardStyle()
        }
    }

    private var currentRPM: Int? {
        model.sensors?.fans.map(\.rpm).max()
    }

    /// The agent only planned the change (fans are a risky command). Nothing
    /// happens until the user says so in the shared plan confirmation.
    private func confirmation(_ pending: TuneViewModel.PendingChange) -> some View {
        PlanConfirmationView(
            model: pending.confirmation, summary: pending.summary,
            confirmTitle: "Apply Fan Setting", onClose: { model.dismissPendingFanChange() }
        )
        .accessibilityIdentifier("fan-plan-confirmation")
    }

    @ViewBuilder
    private func failureNote(_ failure: TuneViewModel.FanFailure) -> some View {
        Text(failure.needsHelper ? FanSelectionAction.openHelperPreferences.hint ?? failure.message : failure.message)
            .symairaText(.caption)
            .foregroundStyle(failure.needsHelper ? SymairaTokens.ink : SymairaTokens.critical)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(failure.needsHelper ? "fan-rights-hint" : "fan-error")
        if failure.needsHelper {
            Button("Open helper settings") {
                preferencesManager.requestFanHelperSetup(hint: FanSelectionAction.openHelperPreferences.hint)
                openPreferences()
            }
            .buttonStyle(.link)
            .symairaText(.caption)
        }
    }
}

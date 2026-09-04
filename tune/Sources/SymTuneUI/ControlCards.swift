import SwiftUI
import SymairaTheme
import SymTuneCore

// MARK: - Display controls

/// Brightness / dim / warmth / extended-brightness sliders.
///
/// Each row owns its drag state (see ``TuneSliderRow``), so moving one slider
/// re-renders that row only — not this card, and not the panel around it.
struct DisplayControlsCard: View {
    let controller: TuneController
    let model: TuneViewModel

    private var isEDRCapable: Bool {
        model.displays.contains { $0.edrCapable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            TuneSliderRow(
                title: "Screen Brightness",
                systemImage: "sun.max.fill",
                value: model.builtinBrightness,
                range: 0.0...1.0
            ) { value in
                try? controller.applyBuiltinBrightness(value)
                model.refreshNow()
            }

            // Software dimming and EDR headroom as one control: centre is the
            // display untouched, and either direction is range symtune adds on
            // top of what the hardware does by itself. See
            // ``BeyondNormalBrightness`` for why the two are folded together
            // and why OS brightness above stays separate.
            CenterAnchoredSliderRow(
                title: "Beyond Normal",
                systemImage: "circle.lefthalf.filled",
                position: beyondNormalPosition,
                minimumLabel: "Darker",
                maximumLabel: "Brighter",
                maximumDisabledNote: isEDRCapable ? nil : "Brighter (unsupported)",
                onCommit: applyBeyondNormal
            )

            // Extended brightness depends on the display granting EDR headroom,
            // which it does not always do. Say what is actually happening
            // instead of leaving the slider looking effective.
            if let note = extendedBrightnessNote {
                Text(note)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TuneSliderRow(
                title: "Color Warmth",
                systemImage: "thermometer.sun.fill",
                value: model.warmth,
                range: 0.0...1.0
            ) { value in
                try? controller.applyWarmth(value)
                model.refreshNow()
            }
        }
        .cardStyle()
    }

    // MARK: - Beyond-normal brightness

    private var beyondNormalPosition: Double {
        BeyondNormalBrightness.position(
            dimFactor: 1.0 - model.dimAmount,
            extendedBrightness: model.overrides.edrBrightness,
            config: controller.config
        )
    }

    /// What "Brighter" is really doing, whenever that differs from the request.
    private var extendedBrightnessNote: String? {
        let status = model.extendedBrightness
        guard let requested = status.requested, let effective = status.effective else { return nil }
        let applied = Int(((effective - 1.0) * 100).rounded())

        switch status.mode {
        case .softwareLift:
            // No EDR headroom: the lift is real but clips the highlights, and
            // it is capped for that reason. Say both.
            return "No HDR headroom right now — lifting +\(applied)% in software, "
                + "so bright areas may flatten. Enable High Dynamic Range for this display "
                + "in System Settings › Displays for the full range."
        case .extendedRange:
            guard effective < requested - 0.01 else { return nil }
            return "Limited to +\(applied)% — that is all the headroom this display grants."
        case nil:
            return nil
        }
    }

    private func applyBeyondNormal(_ position: Double) {
        let resolved = BeyondNormalBrightness.resolve(
            position: position,
            config: controller.config,
            allowsExtendedBrightness: isEDRCapable
        )
        // Both sides are written every time: leaving the other one at its last
        // value would keep it acting after the knob has crossed centre.
        try? controller.applyDim(resolved.dimFactor)
        if isEDRCapable {
            try? controller.applyExtendedBrightness(resolved.extendedBrightness)
        }
        model.refreshNow()
    }
}

// MARK: - Fan control

struct FanControlCard: View {
    let controller: TuneController
    let model: TuneViewModel

    @State private var fanError: String?
    /// Mirrors the selected position so the control can revert on failure.
    @State private var pendingProfile: FanProfile?
    /// True while a privileged write is waiting on the system's own
    /// administrator-password dialog (a few seconds, or longer while the
    /// person is looking for their password) — surfaced so the slider does
    /// not look like it silently ignored the drag.
    @State private var isAwaitingAuthorization = false

    /// See ``MainStatusView/hasFans`` for why an unsupported SMC read (not
    /// just a missing sensors report) must also be treated as "unknown," not
    /// "no fans" — this duplicate exists because ``MainStatusView`` decides
    /// whether to show this card at all, while this one decides what to draw
    /// inside it, and both need the same answer or the card would render
    /// only to immediately show "Not available on this Mac".
    private var hasFans: Bool {
        guard let sensors = model.sensors else { return true }
        guard sensors.smcSupported else { return true }
        return !sensors.fans.isEmpty
    }

    /// The position to draw: the pending one while a change is in flight, so
    /// the control follows the click instead of snapping back until the next
    /// model refresh lands.
    private var selectedProfile: FanProfile {
        pendingProfile ?? model.fanProfile
    }

    var body: some View {
        if hasFans {
            VStack(alignment: .leading, spacing: SymairaSpacing.small) {
                HStack {
                    Label("Fan Control", systemImage: "fanblades.fill")
                        .symairaText(.subheading)
                        .foregroundStyle(SymairaTheme.textSecondary)
                    Spacer()
                    if let rpm = currentRPM {
                        Text("\(rpm) rpm")
                            .symairaText(.caption)
                            .foregroundStyle(SymairaTheme.textMuted)
                    }
                }

                Picker("", selection: profileBinding) {
                    ForEach(FanProfile.ordered, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(selectedProfile.summary)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if isAwaitingAuthorization {
                    Text("Starting the fan governor — you may be asked for your "
                         + "administrator password…")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let fanError {
                    Text(fanError)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                } else if selectedProfile != .system && !model.fanGovernorRunning {
                    // Honest reporting: a selected position with nothing
                    // enforcing it means the fans are still on the firmware
                    // curve, and saying "Cool" would be a lie.
                    Text("Not in effect — no fan governor is running.")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cardStyle()
            .onChange(of: model.fanProfile) { _, _ in
                // The model is authoritative again once it reflects the change.
                pendingProfile = nil
            }
        } else {
            VStack(spacing: 6) {
                HStack {
                    Label("Fan Control", systemImage: "fanblades.fill")
                        .symairaText(.subheading)
                        .foregroundStyle(SymairaTheme.textSecondary)
                    Spacer()
                }
                Text("Not available on this Mac")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            .cardStyle()
        }
    }

    private var currentRPM: Int? {
        model.sensors?.fans.map(\.rpm).max()
    }

    private var profileBinding: Binding<FanProfile> {
        Binding(
            get: { selectedProfile },
            set: { newValue in
                let previous = selectedProfile
                pendingProfile = newValue
                apply {
                    try controller.applyFanProfile(newValue, allowPrivilegeEscalation: true)
                } onFailure: {
                    pendingProfile = previous
                }
            }
        )
    }

    /// Runs `work` off the main actor and reports back on it: a privileged
    /// write can block for as long as the system's own password dialog is on
    /// screen, and that must never freeze the slider or the popover.
    private func apply(
        _ work: @escaping @Sendable () throws -> Void,
        onFailure: @escaping () -> Void = {}
    ) {
        isAwaitingAuthorization = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try work()
                }.value
                isAwaitingAuthorization = false
                fanError = nil
                model.refreshNow()
            } catch {
                isAwaitingAuthorization = false
                fanError = error.localizedDescription
                onFailure()
            }
        }
    }
}

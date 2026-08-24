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
    /// Mirrors the manual-mode switch so the toggle can revert on failure.
    @State private var manualOverride: Bool?

    private var hasFans: Bool {
        guard let fans = model.sensors?.fans else { return true }
        return !fans.isEmpty
    }

    private var isManualMode: Bool {
        manualOverride ?? (model.overrides.fanFraction != nil)
    }

    private var fanFraction: Double {
        model.overrides.fanFraction ?? 0.0
    }

    var body: some View {
        if hasFans {
            VStack(spacing: SymairaSpacing.small) {
                HStack {
                    Label("Fan Control", systemImage: "fanblades.fill")
                        .symairaText(.subheading)
                        .foregroundStyle(SymairaTheme.textSecondary)
                    Spacer()
                    Toggle("", isOn: manualBinding)
                        .toggleStyle(.switch)
                }

                TuneSliderRow(
                    title: "Target Speed",
                    systemImage: "gauge.medium",
                    value: fanFraction,
                    range: 0.0...1.0,
                    isEnabled: isManualMode
                ) { value in
                    apply { try controller.applyFan(fraction: value) }
                }

                if let fanError {
                    Text(fanError)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.critical)
                        .padding(.top, SymairaSpacing.xSmall)
                }
            }
            .cardStyle()
            .onChange(of: model.overrides.fanFraction) { _, _ in
                // The model is authoritative again once it reflects the change.
                manualOverride = nil
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

    private var manualBinding: Binding<Bool> {
        Binding(
            get: { isManualMode },
            set: { newValue in
                manualOverride = newValue
                apply {
                    if newValue {
                        try controller.applyFan(fraction: fanFraction)
                    } else {
                        try controller.restoreFanAuto()
                    }
                } onFailure: {
                    manualOverride = !newValue
                }
            }
        )
    }

    private func apply(
        _ work: () throws -> Void,
        onFailure: () -> Void = {}
    ) {
        do {
            try work()
            fanError = nil
            model.refreshNow()
        } catch {
            fanError = error.localizedDescription
            onFailure()
        }
    }
}

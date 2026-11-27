import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Power & Fans, third in the sidebar.
// 2. Job: choose the fan profile (and Cool target) and the battery charge limit.
// 3. Data: the agent's `fan.status` and `status` topics. Fan and charge-limit changes are risky:
//    the agent returns a plan and the shared plan confirmation applies it.
// 4. States: loading (battery, sensors), empty (no battery, no fans, no charge limit on this Mac
//    each say so), error (a refused change shows under its card), unreachable (the shell's diagnosis).
// 5. Density: dashboard grid, 960 pt.
// 6. Platform: macOS workspace. The fan helper setup stays in Preferences.

@MainActor
struct PowerFansPage: View {
    let context: CockpitPageContext

    private var model: TuneViewModel { context.model }

    var body: some View {
        SymairaPage(
            title: CockpitDestination.powerFans.title, subtitle: CockpitDestination.powerFans.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                BatterySection(model: model)
                PairedCards {
                    FanControlCard(
                        model: model, preferencesManager: context.preferencesManager,
                        openPreferences: context.openPreferences
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    ChargeLimitCard(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// Reads only `model.battery`.
private struct BatterySection: View {
    let model: TuneViewModel

    var body: some View {
        BatteryCard(battery: model.battery)
    }
}

/// Charge, health and wear of the battery as the agent reports it.
struct BatteryCard: View {
    let battery: BatteryReport?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("BATTERY")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)
            if let battery {
                if battery.present {
                    HStack(alignment: .top, spacing: SymairaSpacing.xLarge) {
                        CockpitStatGauge(
                            value: battery.currentCapacityPercent.map(Double.init) ?? 0,
                            label: "Charge", display: battery.currentCapacityPercent.map { "\($0) %" } ?? "—",
                            detail: state(battery)
                        )
                        CockpitStatGauge(
                            value: (battery.appleMaximumCapacityPercent ?? battery.healthPercent).map(Double.init) ?? 0,
                            label: "Maximum Capacity",
                            display: (battery.appleMaximumCapacityPercent ?? battery.healthPercent).map { "\($0) %" } ?? "—",
                            detail: battery.appleCondition
                        )
                        CockpitStatValue(
                            value: battery.cycleCount.map(String.init) ?? "—",
                            label: "Cycles"
                        )
                        if let celsius = battery.temperatureCelsius {
                            CockpitStatValue(value: String(format: "%.0f °C", celsius), label: "Temperature")
                        }
                    }
                } else {
                    Text("No battery detected. This Mac runs on mains power only.")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                }
            } else {
                ProgressView("Reading battery…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityIdentifier("battery-card")
    }

    private func state(_ battery: BatteryReport) -> String {
        if battery.charging == true { return "Charging" }
        return battery.externalConnected == true ? "On AC" : "On Battery"
    }
}

import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Overview, the first of the sidebar.
// 2. Job: see at a glance whether this Mac is fine (read-only; the controls are on Display and Power & Fans).
// 3. Data: the agent's `metrics` and `status` topics, subscribed while the window is on screen.
// 4. States: loading (each card says what it waits for), empty (a card without sensors says so),
//    error (a reading the app could not decode shows the diagnosis), unreachable (the shell's
//    diagnosis replaces the page).
// 5. Density: dashboard grid, 960 pt.
// 6. Platform: macOS workspace; no preference keys of its own.

@MainActor
struct OverviewPage: View {
    let context: CockpitPageContext

    private var model: TuneViewModel { context.model }

    var body: some View {
        SymairaPage(
            title: CockpitDestination.overview.title, subtitle: CockpitDestination.overview.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                if let diagnosis = model.diagnosis {
                    AgentDiagnosisCard(diagnosis: diagnosis, restart: { model.restartAgent() })
                }
                LiveSummaryStrip(model: model, isExpanded: true)
                PairedCards {
                    HealthSection(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    SystemStatusSection(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                SensorsSection(model: model)
                MetricsHistorySection(model: model)
                readout
            }
        }
    }

    /// Where the readout appears and what the HUD shows; the same cards the menu
    /// bar's preferences use, kept here because the window is where they are chosen.
    private var readout: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            GroupLabel("Menu Bar & HUD")
            MenuBarVisibilityCard(
                preferences: context.preferencesManager,
                aiUsage: context.aiUsageModel.preferences,
                model: model,
                hasEnabledAIProviders: !context.aiUsageModel.rows.isEmpty,
                readout: context.readoutPreferences,
                hudDock: context.hudDockPreferences
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if let readout = context.readoutPreferences, let dock = context.hudDockPreferences,
               let items = context.hudItemPreferences {
                HUDContentSection(
                    readout: readout, dock: dock, items: items, preferences: context.preferencesManager
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Health

/// Reads only `model.health`, so a metrics tick does not invalidate it.
private struct HealthSection: View {
    let model: TuneViewModel

    var body: some View {
        HealthCard(health: model.health)
    }
}

/// The agent's health score and the advice that came with it.
struct HealthCard: View {
    let health: TuneViewModel.Health?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("HEALTH")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)
            if let health {
                HStack(alignment: .top, spacing: SymairaSpacing.xLarge) {
                    CockpitStatGauge(value: Double(health.score), label: "Health Score", display: "\(health.score)", detail: "of 100")
                        .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                        Text(health.message)
                            .symairaText(.body, respectsForeground: false)
                            .foregroundStyle(SymairaTokens.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if health.recommendations.isEmpty {
                            Text("Nothing to do right now.")
                                .symairaText(.caption)
                                .foregroundStyle(SymairaTokens.ink3)
                        }
                        ForEach(Array(health.recommendations.enumerated()), id: \.offset) { _, advice in
                            Label(advice, symairaIcon: .tip, iconSize: 14)
                                .symairaText(.caption, respectsForeground: false)
                                .foregroundStyle(SymairaTokens.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                ProgressView("Reading health…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityIdentifier("health-card")
    }
}

// MARK: - Sensors

private struct SensorsSection: View {
    let model: TuneViewModel

    var body: some View {
        SensorsCard(sensors: model.sensors)
    }
}

/// Fans and temperatures as the SMC reports them: the hottest few, the rest on demand.
struct SensorsCard: View {
    let sensors: SensorReport?
    @State private var showsAll = false

    private static let collapsedCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("SENSORS")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityIdentifier("sensors-card")
    }

    @ViewBuilder
    private var content: some View {
        if let sensors {
            if !sensors.smcSupported {
                note("SMC unavailable on this macOS build. Thermal pressure is still reported above.")
            } else if sensors.temperatures.isEmpty && sensors.fans.isEmpty {
                note("No detailed sensors reported. This Mac exposes none to Cockpit.")
            } else {
                readings(sensors)
            }
        } else {
            ProgressView("Reading sensors…")
        }
    }

    private func readings(_ sensors: SensorReport) -> some View {
        let temperatures = sensors.temperatures.sorted { $0.celsius > $1.celsius }
        let shown = showsAll ? temperatures : Array(temperatures.prefix(Self.collapsedCount))
        return VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            ForEach(sensors.fans, id: \.index) { fan in
                row(fan.label, "\(fan.rpm) rpm")
            }
            if !sensors.fans.isEmpty && !shown.isEmpty { SymairaFormDivider() }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, reading in
                row(reading.label, String(format: "%.1f °C", reading.celsius))
            }
            if temperatures.count > Self.collapsedCount {
                Button(showsAll ? "Show Fewer Sensors" : "Show All \(temperatures.count) Sensors") { showsAll.toggle() }
                    .buttonStyle(.link)
                    .symairaText(.caption)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .symairaText(.caption, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink)
            Spacer(minLength: SymairaSpacing.small)
            Text(value)
                .symairaText(.caption, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink2)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .symairaText(.caption)
            .foregroundStyle(SymairaTokens.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

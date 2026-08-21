import SwiftUI
import SymairaTheme
import SymTuneCore

// MARK: - Shared card chrome

/// The panel background shared by every card in the status popover.
struct CardStyle: ViewModifier {
    var borderColor: Color = SymairaTheme.borderGlass

    func body(content: Content) -> some View {
        content
            .padding(SymairaSpacing.medium)
            .background(SymairaTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.card)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(borderColor: Color = SymairaTheme.borderGlass) -> some View {
        modifier(CardStyle(borderColor: borderColor))
    }
}

// MARK: - Header / footer

struct StatusHeaderView: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SYMAIRA TUNE")
                    .symairaText(.heading)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                Text("v\(TuneVersion.current)")
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            Spacer()
            Circle()
                .fill(SymairaTheme.positive.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, SymairaSpacing.xSmall)
    }
}

/// The three numbers people open this panel for, on one line under the title.
///
/// Reads `model.metrics` in its own body so a metrics tick invalidates this
/// strip and nothing else (see ``MainStatusView``).
@MainActor
struct LiveSummaryStrip: View {
    let model: TuneViewModel

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            chip("cpu", "cpu.fill", cpuText)
            chip("ram", "memorychip.fill", memoryText)
            chip("thermal", "thermometer.medium", thermalText, tint: thermalColor)
        }
        .padding(.horizontal, SymairaSpacing.xSmall)
    }

    private func chip(
        _ id: String,
        _ symbol: String,
        _ text: String,
        tint: Color = SymairaTheme.goldPrimary
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(text)
                .symairaText(.monoSmall)
                .foregroundStyle(SymairaTheme.textPrimary)
        }
        .padding(.horizontal, SymairaSpacing.small)
        .padding(.vertical, 3)
        .background(SymairaTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.control)
                .stroke(SymairaTheme.borderGlass, lineWidth: 1)
        )
        .accessibilityIdentifier(id)
    }

    // Both chips go through the shared core formatter rather than formatting
    // here: `totalUtilization` is a fraction, not a percentage, and a second
    // copy of that knowledge in the view is exactly how this strip first
    // shipped a CPU reading of "0%" next to a metrics card saying 26%.
    private var cpuText: String {
        guard let report = model.metrics else { return "—" }
        return MetricFormatting.fallbackValue(.cpu, report: report) ?? "—"
    }

    private var memoryText: String {
        guard let report = model.metrics else { return "—" }
        return MetricFormatting.fallbackValue(.memory, report: report, style: model.metricStyle(for: .memory)) ?? "—"
    }

    /// Sensors are only polled while the panel is open, so the very first frame
    /// after opening has none yet — say so instead of claiming "nominal".
    private var thermalText: String {
        model.sensors?.thermalPressure ?? "…"
    }

    private var thermalColor: Color {
        switch thermalText.lowercased() {
        case "nominal": return SymairaTheme.positive
        case "fair": return SymairaTheme.warning
        default: return SymairaTheme.critical
        }
    }
}

struct StatusFooterView: View {
    let openPreferences: () -> Void

    var body: some View {
        HStack {
            Button(action: openPreferences) {
                Text("Preferences\u{2026}")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                    .padding(.horizontal, SymairaSpacing.medium)
                    .padding(.vertical, SymairaSpacing.small)
                    .background(SymairaTheme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: SymairaRadius.control)
                            .stroke(SymairaTheme.borderGlass, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.bgDark)
                    .padding(.horizontal, SymairaSpacing.large)
                    .padding(.vertical, SymairaSpacing.small)
                    .background(SymairaTheme.goldPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, SymairaSpacing.xSmall)
    }
}

// MARK: - System status

/// Battery and thermal readout.
///
/// `Equatable` on the two reports: while neither changes — which is most
/// refreshes — SwiftUI skips this subtree entirely.
struct SystemStatusCard: View, Equatable {
    let battery: BatteryReport?
    let sensors: SensorReport?

    var body: some View {
        VStack(spacing: SymairaSpacing.small - 2) {
            HStack {
                Text("SYSTEM STATUS")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTheme.textMuted)
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: batteryIcon)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(batteryState)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textPrimary)
                    Text(batteryDetails)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.vertical, SymairaSpacing.xSmall)

            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle.fill")
                    .foregroundStyle(SymairaTheme.goldPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Thermal:")
                            .symairaText(.caption)
                            .foregroundStyle(SymairaTheme.textPrimary)
                        Text(sensors?.thermalPressure ?? "nominal")
                            .symairaText(.caption)
                            .foregroundStyle(thermalColor)
                    }
                    if let details = sensorDetails {
                        Text(details)
                            .symairaText(.caption)
                            .foregroundStyle(SymairaTheme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, SymairaSpacing.xSmall)
        }
        .cardStyle()
    }

    // MARK: Derived text

    private var batteryIcon: String {
        guard let battery, battery.present else { return "battery.0" }
        if battery.charging == true { return "battery.100.bolt" }
        guard let percent = battery.currentCapacityPercent else { return "battery.50" }
        if percent > 80 { return "battery.100" }
        if percent > 50 { return "battery.75" }
        if percent > 25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryState: String {
        guard let battery, battery.present else { return "No Battery Detected" }
        let capacity = battery.currentCapacityPercent.map { "\($0)%" } ?? "Unknown"
        let state = battery.charging == true ? "Charging" : "On Battery"
        return "\(capacity) (\(state))"
    }

    private var batteryDetails: String {
        guard let battery, battery.present else { return "Desktop Mac" }
        let health = battery.healthPercent.map { "\($0)% Health" } ?? ""
        let cycles = battery.cycleCount.map { "\($0) Cycles" } ?? ""
        let separator = !health.isEmpty && !cycles.isEmpty ? " · " : ""
        return "\(health)\(separator)\(cycles)"
    }

    private var thermalColor: Color {
        switch (sensors?.thermalPressure ?? "nominal").lowercased() {
        case "nominal": return SymairaTheme.positive
        case "fair": return SymairaTheme.warning
        default: return SymairaTheme.critical
        }
    }

    private var sensorDetails: String? {
        guard let sensors, !sensors.temperatures.isEmpty || !sensors.fans.isEmpty else {
            // Two different situations, previously reported with one (wrong)
            // sandbox message: the SMC never answered at all, or it answered
            // but reports no sensors this Mac exposes to us.
            guard let sensors else { return nil }
            return sensors.smcSupported
                ? "No detailed sensors reported"
                : "SMC unavailable on this macOS build"
        }
        var parts: [String] = []
        if let cpu = sensors.temperatures.first(where: { $0.label.contains("CPU") }) {
            parts.append(String(format: "CPU: %.1f°C", cpu.celsius))
        }
        if let fan = sensors.fans.first {
            parts.append("Fan: \(fan.rpm) RPM")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Connected displays

/// The attached-display list. Changes only when a monitor is plugged in, so
/// `Equatable` keeps it out of every other refresh.
struct DisplaysCard: View, Equatable {
    let displays: [DisplayInfo]

    var body: some View {
        VStack(spacing: SymairaSpacing.xSmall + 1) {
            HStack {
                Text("CONNECTED DISPLAYS")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTheme.textMuted)
                Spacer()
            }

            if displays.isEmpty {
                Text("No active displays found")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
            } else {
                ForEach(displays, id: \.displayID) { display in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(display.name)
                                .symairaText(.caption)
                                .foregroundStyle(SymairaTheme.textPrimary)
                            Text(display.isBuiltin == true ? "Built-in Display" : "External Display")
                                .symairaText(.caption)
                                .foregroundStyle(SymairaTheme.textSecondary)
                        }
                        Spacer()
                        if display.edrCapable {
                            Text("EDR \(String(format: "%.1f", display.maxEDRHeadroom))x")
                                .symairaText(.monoSmall)
                                .padding(.horizontal, SymairaSpacing.small)
                                .padding(.vertical, SymairaSpacing.xSmall)
                                .background(SymairaTheme.goldPrimary.opacity(0.12))
                                .foregroundStyle(SymairaTheme.goldPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                        }
                    }
                    .padding(.vertical, SymairaSpacing.xSmall)
                }
            }
        }
        .cardStyle()
    }
}

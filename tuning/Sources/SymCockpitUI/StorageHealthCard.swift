import SwiftUI
import SymCockpitCore
import SymairaTheme

/// SMART health of each drive the agent can read, the verdict of every rule, and the recorded history.
@MainActor
struct StorageHealthCard: View {
    let model: StorageHealthModel
    @State private var showsAllHistory = false

    private static let collapsedHistory = 8

    var body: some View {
        PageCard(
            title: "Drive Health", icon: .storage,
            detail: "What the drive reports about itself (NVMe SMART) and how Cockpit's rules grade it.",
            identifier: "storage-health"
        ) {
            Button("Refresh Health") { Task { await model.load() } }
                .symairaButtonStyle(.secondary)
                .disabled(model.report.isLoading || model.history.isLoading)
            SectionStateView(
                state: model.report, loading: "Reading drive health…",
                retry: { Task { await model.load() } },
                idle: { MutedNote("Drive health has not been read yet.") },
                loaded: { report in devices(report) }
            )
            SymairaFormDivider()
            history
        }
    }

    // MARK: Devices

    private func devices(_ report: DriveHealth) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            if report.devices.isEmpty {
                MutedNote("No SMART-capable NVMe drives found.")
            } else {
                let grade = StorageFormat.grade(report.overallGrade)
                SymairaStatusLabel("Overall: \(grade.label)", tone: grade.tone)
                ForEach(Array(report.devices.enumerated()), id: \.offset) { _, device in
                    DeviceHealthView(device: device)
                }
                MutedNote("Measured \(report.measuredAt). History contains measurements recorded by the CLI.")
            }
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("HISTORY")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)
            SectionStateView(
                state: model.history, loading: "Reading the recorded history…",
                retry: { Task { await model.load() } },
                idle: { MutedNote("The history has not been read yet.") },
                loaded: { samples in historyRows(samples) }
            )
        }
    }

    @ViewBuilder
    private func historyRows(_ samples: [HealthSample]) -> some View {
        if samples.isEmpty {
            MutedNote("Nothing recorded yet. Run `symcockpit storage health` in Terminal to record a measurement; each one is kept here.")
        } else {
            let shown = showsAllHistory ? samples : Array(samples.prefix(Self.collapsedHistory))
            Grid(alignment: .leading, horizontalSpacing: SymairaSpacing.medium, verticalSpacing: SymairaSpacing.xSmall) {
                GridRow {
                    header("Time")
                    header("Drive")
                    header("Grade")
                    header("Temp.").gridColumnAlignment(.trailing)
                    header("Spare").gridColumnAlignment(.trailing)
                    header("Used").gridColumnAlignment(.trailing)
                    header("Errors").gridColumnAlignment(.trailing)
                }
                ForEach(shown) { sample in
                    GridRow {
                        Text(sample.date.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? sample.measuredAt)
                            .monospacedDigit()
                        Text(sample.model.isEmpty ? sample.deviceKey : sample.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SymairaStatusLabel(StorageFormat.grade(sample.grade).label, tone: StorageFormat.grade(sample.grade).tone)
                        Text(sample.temperatureCelsius.map { String(format: "%.0f °C", $0) } ?? "—").monospacedDigit()
                        Text("\(sample.availableSparePercent) %").monospacedDigit()
                        Text("\(sample.percentageUsed) %").monospacedDigit()
                        Text(sample.mediaErrors.formatted(.number.precision(.fractionLength(0)))).monospacedDigit()
                    }
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .help(sample.changes?.map(\.message).joined(separator: "\n") ?? "Oldest measurement")
                    ForEach(sample.changes ?? [], id: \.message) { change in
                        GridRow {
                            Text("")
                            Label(change.message, symairaIcon: .warning, iconSize: 12)
                                .symairaText(.caption, respectsForeground: false)
                                .foregroundStyle(SymairaTokens.warning)
                                .gridCellColumns(6)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recorded drive health")
            if samples.count > Self.collapsedHistory {
                Button(showsAllHistory ? "Show Fewer Measurements" : "Show All \(samples.count) Measurements") {
                    showsAllHistory.toggle()
                }
                .buttonStyle(.link)
                .symairaText(.caption)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .symairaText(.caption)
            .foregroundStyle(SymairaTokens.ink3)
    }
}

/// One drive: its grade, the figures that matter and what each rule found.
private struct DeviceHealthView: View {
    let device: DriveHealth.Device

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                Text(device.model ?? "Unnamed drive")
                    .symairaText(.body, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                Text([device.location, device.firmware.map { "firmware \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                Spacer(minLength: SymairaSpacing.small)
                SymairaStatusLabel(StorageFormat.grade(device.grade).label, tone: StorageFormat.grade(device.grade).tone)
            }
            if device.access.status != "ok" {
                SymairaNotice(
                    title: "SMART Could Not Be Read",
                    message: "SMART is unavailable at stage “\(device.access.stage ?? "unknown")” (code \(device.access.code ?? "none")).",
                    tone: .warning
                )
            } else if let metrics = device.metrics {
                tiles(metrics)
                if !device.checks.isEmpty { checks }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Health of \(device.model ?? device.key)")
    }

    private func tiles(_ metrics: DriveHealth.Metrics) -> some View {
        HStack(alignment: .top, spacing: SymairaSpacing.xLarge) {
            SymairaStatTile(
                value: metrics.temperatureCelsius.map { String(format: "%.0f °C", $0.value) } ?? "—",
                label: "Temperature", showsCard: false
            )
            SymairaStatTile(
                value: metrics.percentageUsed.map { "\(Int($0.value)) %" } ?? "—",
                label: "Wear", detail: metrics.availableSpare.map { "\(Int($0.value)) % spare" }, showsCard: false
            )
            SymairaStatTile(
                value: metrics.dataWritten.map { StorageFormat.measuredBytes($0.value) } ?? "—",
                label: "Written", detail: metrics.dataRead.map { "\(StorageFormat.measuredBytes($0.value)) read" }, showsCard: false
            )
            SymairaStatTile(
                value: metrics.powerOnHours.map { "\($0.value.formatted(.number)) h" } ?? "—",
                label: "Power-On Time", detail: metrics.powerCycles.map { "\($0.value.formatted(.number)) cycles" }, showsCard: false
            )
            SymairaStatTile(
                value: metrics.mediaErrors.map { $0.value.formatted(.number) } ?? "—",
                label: "Media Errors", detail: metrics.unsafeShutdowns.map { "\($0.value.formatted(.number)) unsafe shutdowns" },
                showsCard: false
            )
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            ForEach(device.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                    SymairaStatusLabel(StorageFormat.grade(check.grade).label, tone: StorageFormat.grade(check.grade).tone)
                        .frame(width: 96, alignment: .leading)
                    Text(check.message)
                        .symairaText(.caption, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

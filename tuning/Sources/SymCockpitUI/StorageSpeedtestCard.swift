import SwiftUI
import SymCockpitCore
import SymairaTheme

@MainActor
struct StorageSpeedtestCard: View {
    @Bindable var model: SpeedtestModel
    let gate: AgentWorkGate
    let volumes: [StorageVolumeReport]

    private var targets: [(value: String?, label: String)] {
        [(nil, "Home folder")] + volumes.compactMap { volume in
            guard volume.mountPath.hasPrefix("/Volumes/"), volume.isReadOnly != true else { return nil }
            return (volume.mountPath, "\(volume.name) (\(volume.mountPath))")
        }
    }

    private var targetAvailable: Bool { targets.contains { $0.value == model.target } }
    private var canRun: Bool { !gate.isBusy && targetAvailable && SpeedtestModel.sizes.contains(model.sizeMiB) }

    var body: some View {
        PageCard(
            title: "Speed Test", icon: .chart,
            detail: "Test your home folder or a writable drive mounted under /Volumes.",
            identifier: "storage-speedtest"
        ) {
            HStack(spacing: SymairaSpacing.small) {
                SymairaFilterMenu(
                    "Test volume", selection: Binding(get: { model.target }, set: { model.chooseTarget($0) }),
                    options: targets
                )
                TextField("Size (MiB)", value: $model.sizeMiB, format: .number)
                    .frame(idealWidth: 72, maxWidth: 88)
                    .help("Test file size, 1–1024 MiB")
                MutedNote("MiB")
                Button("Run Speed Test") { Task { await model.run() } }
                    .symairaButtonStyle(.secondary)
                    .disabled(!canRun)
            }
            .disabled(gate.isBusy)
            if !SpeedtestModel.sizes.contains(model.sizeMiB) {
                SymairaNotice(message: "Enter a file size from 1 to 1024 MiB.", tone: .warning)
            }
            if !targetAvailable {
                SymairaNotice(message: "The selected volume is unavailable. Choose a mounted writable volume.", tone: .warning)
            }
            SectionStateView(
                state: model.state, loading: "Writing and reading the test file…",
                retry: canRun ? { Task { await model.run() } } : nil,
                idle: { MutedNote("The agent creates a temporary file on the selected volume, measures sequential write and read, then removes it.") },
                loaded: { report in results(report) }
            )
        }
    }

    private func results(_ report: SpeedResult) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            HStack(alignment: .top, spacing: SymairaSpacing.xLarge) {
                phase("Write", report.write)
                phase("Read", report.read)
            }
            MutedNote("\(report.target) · \(report.sizeMib) MiB")
            if report.cacheMode == "uncached" && !report.cacheModeApplied {
                SymairaNotice(message: "macOS did not apply cache bypass. These speeds may include cached data.", tone: .warning)
            } else {
                MutedNote(report.cacheMode == "uncached" ? "Cache bypass applied." : "Cache mode: \(report.cacheMode).")
            }
            if report.cleanup.removed {
                MutedNote("Temporary test file removed.")
            } else {
                SymairaNotice(
                    title: "Temporary Files Remain",
                    message: report.cleanup.error ?? "The agent could not remove its test files.",
                    tone: .warning
                )
            }
        }
    }

    private func phase(_ name: String, _ phase: SpeedResult.Phase) -> some View {
        SymairaStatTile(
            value: "\(phase.mibPerS.formatted(.number.precision(.fractionLength(1)))) MiB/s",
            label: name,
            detail: "\(phase.mbPerS.formatted(.number.precision(.fractionLength(1)))) MB/s · \(phase.durationSeconds.formatted(.number)) s",
            showsCard: false
        )
    }
}

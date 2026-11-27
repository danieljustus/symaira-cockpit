import AppKit
import SwiftUI
import SymairaTheme
import SymCockpitCore

/// "What is using my CPU / memory right now?" — one click away in the popover.
///
/// Collapsed by default and collapsed = free: the card only samples the process
/// table while it is expanded (see ``ProcessesViewModel``), so the answer is
/// there when asked for and costs nothing when not.
@MainActor
struct TopProcessesCard: View {
    let model: ProcessesViewModel

    /// Remembered across launches: whoever opens this once usually wants it.
    @AppStorage("com.symaira.tune.processesExpanded") private var isExpanded = false

    var body: some View {
        VStack(spacing: SymairaSpacing.small) {
            header

            if isExpanded {
                ProcessList(model: model)
            }
        }
        .cardStyle()
        .onChange(of: isExpanded) { _, expanded in
            model.setVisible(expanded)
        }
        .onAppear { model.setVisible(isExpanded) }
        .onDisappear { model.setVisible(false) }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: SymairaSpacing.xSmall) {
                SymairaIconView(isExpanded ? .expand : .forward, size: 12)
                    .foregroundStyle(SymairaTokens.ink3)
                Text("TOP PROCESSES")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTokens.ink3)
                Spacer()
                // No value while collapsed: the card is not sampling then, and
                // a number left over from the last time it was open would be a
                // stale reading with nothing to say so.
                if !isExpanded {
                    Text("show")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the process list" : "Show the busiest processes")
    }

}

/// Shared ranking and row interaction for the popover and Processes page.
@MainActor
struct ProcessList: View {
    let model: ProcessesViewModel
    var termination: ProcessKillModel?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            rankings
                .disabled(termination?.confirmation != nil)
            if let termination {
                terminationControls(termination)
            }
        }
    }

    private var rankings: some View {
        VStack(spacing: SymairaSpacing.xSmall) {
            SymairaSegmentedControl(
                "Sort processes by", selection: sortBinding,
                options: ProcessSortKey.allCases.map { ($0, $0.displayName) }
            )

            if let problem = model.problem {
                SymairaNotice(message: problem, tone: .warning)
                Button("Try Again") { model.refreshNow() }
                    .symairaButtonStyle(.secondary)
            } else if !model.hasSample || model.report.sortedBy != model.sortedBy {
                ProgressView("Sampling processes…")
            } else if model.report.processes.isEmpty {
                if model.sortedBy == .gpu {
                    gpuEmptyState
                } else {
                    MutedNote("No readable processes.")
                }
            } else {
                ForEach(model.report.processes) { process in
                    ProcessRow(
                        process: process,
                        sortedBy: model.report.sortedBy,
                        fraction: fraction(for: process),
                        isSelected: model.selectedPID == process.pid,
                        protection: termination?.protection(for: process.pid),
                        onTap: { toggleSelection(process.pid) }
                    )
                }
            }

            if termination != nil, model.hasSample, model.problem == nil,
               model.report.sortedBy == model.sortedBy, model.report.unreadableProcessCount > 0 {
                MutedNote("\(model.report.unreadableProcessCount) processes were unreadable to the agent.")
            }
            footer
        }
    }

    @ViewBuilder
    private func terminationControls(_ termination: ProcessKillModel) -> some View {
        SymairaFormDivider()
        if let confirmation = termination.confirmation {
            PlanConfirmationView(
                model: confirmation, summary: "Sends SIGTERM if the process still matches the identity in this plan.",
                confirmTitle: "End Process", onClose: { termination.close() }
            )
        } else if !termination.isAvailable {
            SymairaNotice(message: "This agent does not offer process termination.", tone: .warning)
        } else {
            MutedNote("The agent protects its own process, system PIDs below \(termination.minimumPID), and processes owned by other users.")
            if model.hasSample, model.problem == nil, model.report.sortedBy == model.sortedBy,
               let process = model.report.processes.first(where: { $0.pid == model.selectedPID }),
               termination.protection(for: process.pid) == nil {
                let refusal = termination.refusal(for: process.pid, name: process.name)
                if let refusal {
                    SymairaNotice(title: "Process Unavailable", message: refusal, tone: .warning)
                }
                Button(refusal == nil ? "Review End Process Plan…" : "Check Again") {
                    Task { await termination.request(pid: process.pid, name: process.name) }
                }
                .symairaButtonStyle(.primary)
                .disabled(termination.requesting != nil)
                .accessibilityLabel(refusal == nil
                    ? "Review plan to end \(process.name), PID \(process.pid)"
                    : "Check PID \(process.pid) again")
            }
            if let pid = termination.requesting {
                ProgressView("Preparing termination plan for PID \(pid)…")
            }
            if let failure = termination.failure {
                SymairaNotice(message: failure, tone: .warning)
            }
        }
    }

    /// GPU sampling needs root (`powermetrics` refuses to run otherwise), so
    /// it never runs on the normal polling timer — only this explicit,
    /// one-shot action, which prompts once for an administrator password
    /// rather than on every sample tick.
    private var gpuEmptyState: some View {
        VStack(spacing: SymairaSpacing.xSmall) {
            Text(model.isLoadingGPUUsage
                ? "Loading GPU usage…"
                : (model.report.notes.first ?? "No GPU data."))
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
                .multilineTextAlignment(.center)
            if termination != nil {
                MutedNote("Per-process GPU data depends on the hardware counters and the agent’s privileges.")
            } else if !model.isLoadingGPUUsage {
                Button("Load GPU Usage…") {
                    model.loadGPUUsageWithElevation()
                }
                .buttonStyle(.plain)
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink)
                .help("Prompts once for your administrator password — powermetrics needs root to report per-process GPU time.")
            }
        }
        .padding(.vertical, SymairaSpacing.small)
    }

    private var footer: some View {
        HStack {
            if model.isWarmingUp, model.hasSample, model.report.sortedBy == .cpu, !model.report.processes.isEmpty {
                // Honest about the one thing that cannot be instant: CPU is a
                // rate, so it needs a second sample.
                Text("measuring CPU…")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            } else if model.hasSample, model.problem == nil, model.report.sortedBy == model.sortedBy {
                Text("\(model.report.sampledProcessCount) processes")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            }
            Spacer()
            if termination == nil {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Text("Activity Monitor")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink2)
                }
                .buttonStyle(.plain)
                .help("Open Activity Monitor for the full picture")
            }
        }
        .padding(.top, SymairaSpacing.xSmall)
    }

    // MARK: - Derived

    private var sortBinding: Binding<ProcessSortKey> {
        Binding(get: { model.sortedBy }, set: { model.sortedBy = $0 })
    }

    private func toggleSelection(_ pid: Int32) {
        model.selectedPID = model.selectedPID == pid ? nil : pid
    }

    /// Bar length relative to the busiest process in the list, so the ranking
    /// stays readable whether the top process is at 3% or 300%.
    private func fraction(for process: ProcessUsage) -> Double {
        let values = model.report.processes.map { candidate -> Double in
            switch model.report.sortedBy {
            case .cpu: return candidate.cpuPercent ?? 0
            case .memory: return Double(candidate.memoryBytes)
            case .gpu: return candidate.gpuPercent ?? 0
            }
        }
        guard let maximum = values.max(), maximum > 0 else { return 0 }
        let own: Double
        switch model.report.sortedBy {
        case .cpu: own = process.cpuPercent ?? 0
        case .memory: own = Double(process.memoryBytes)
        case .gpu: own = process.gpuPercent ?? 0
        }
        return min(max(own / maximum, 0), 1)
    }
}

/// One process: name, usage bar, value — and its PID/threads when tapped.
private struct ProcessRow: View {
    let process: ProcessUsage
    let sortedBy: ProcessSortKey
    let fraction: Double
    let isSelected: Bool
    let protection: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SymairaSpacing.small) {
                    Text(process.name)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SymairaSpacing.small)
                    Text(valueText)
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTokens.ink)
                }

                ProgressView(value: fraction)
                    .progressViewStyle(CockpitProgressStyle(height: 3))
                    .accessibilityLabel("Relative usage for \(process.name)")
                    .accessibilityValue(valueText)

                if let protection {
                    MutedNote(protection)
                }
                if isSelected {
                    Text(detailText)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("PID \(process.pid)")
    }

    private var valueText: String {
        switch sortedBy {
        case .cpu:
            return process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        case .memory:
            return MetricFormatting.bytes(process.memoryBytes)
        case .gpu:
            return process.gpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        }
    }

    /// The other resource is shown alongside the identity: a process at the top
    /// of the CPU list is usually worth checking for memory as well. GPU rows
    /// carry no CPU/memory figures of their own — a different, privileged
    /// data source — so only PID/threads are shown.
    private var detailText: String {
        var parts = ["PID \(process.pid)"]
        if let threads = process.threadCount {
            parts.append("\(threads) threads")
        }
        switch sortedBy {
        case .cpu:
            parts.append(MetricFormatting.bytes(process.memoryBytes))
        case .memory:
            if let cpu = process.cpuPercent {
                parts.append(String(format: "%.1f%% CPU", cpu))
            }
        case .gpu:
            break
        }
        return parts.joined(separator: " · ")
    }
}

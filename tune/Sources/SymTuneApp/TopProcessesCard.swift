import AppKit
import SwiftUI
import SymairaTheme
import SymTuneCore

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
    @State private var selectedPID: Int32?

    var body: some View {
        VStack(spacing: SymairaSpacing.small) {
            header

            if isExpanded {
                content
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
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SymairaTheme.textMuted)
                Text("TOP PROCESSES")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTheme.textMuted)
                Spacer()
                // No value while collapsed: the card is not sampling then, and
                // a number left over from the last time it was open would be a
                // stale reading with nothing to say so.
                if !isExpanded {
                    Text("show")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the process list" : "Show the busiest processes")
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: SymairaSpacing.xSmall) {
            Picker("", selection: sortBinding) {
                ForEach(ProcessSortKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.report.processes.isEmpty {
                Text(model.isWarmingUp ? "Sampling…" : "No readable processes.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .padding(.vertical, SymairaSpacing.small)
            } else {
                ForEach(model.report.processes) { process in
                    ProcessRow(
                        process: process,
                        sortedBy: model.report.sortedBy,
                        fraction: fraction(for: process),
                        isSelected: selectedPID == process.pid,
                        onTap: { toggleSelection(process.pid) }
                    )
                }
            }

            footer
        }
    }

    private var footer: some View {
        HStack {
            if model.isWarmingUp, model.report.sortedBy == .cpu {
                // Honest about the one thing that cannot be instant: CPU is a
                // rate, so it needs a second sample.
                Text("measuring CPU…")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            } else {
                Text("\(model.report.sampledProcessCount) processes")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Text("Activity Monitor")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open Activity Monitor for the full picture")
        }
        .padding(.top, SymairaSpacing.xSmall)
    }

    // MARK: - Derived

    private var sortBinding: Binding<ProcessSortKey> {
        Binding(get: { model.sortedBy }, set: { model.sortedBy = $0 })
    }

    private func toggleSelection(_ pid: Int32) {
        selectedPID = selectedPID == pid ? nil : pid
    }

    /// Bar length relative to the busiest process in the list, so the ranking
    /// stays readable whether the top process is at 3% or 300%.
    private func fraction(for process: ProcessUsage) -> Double {
        let values = model.report.processes.map { candidate -> Double in
            switch model.report.sortedBy {
            case .cpu: return candidate.cpuPercent ?? 0
            case .memory: return Double(candidate.memoryBytes)
            }
        }
        guard let maximum = values.max(), maximum > 0 else { return 0 }
        let own: Double
        switch model.report.sortedBy {
        case .cpu: own = process.cpuPercent ?? 0
        case .memory: own = Double(process.memoryBytes)
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SymairaSpacing.small) {
                    Text(process.name)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SymairaSpacing.small)
                    Text(valueText)
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTheme.goldSecondary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SymairaTheme.borderGlass)
                        Capsule()
                            .fill(SymairaTheme.goldPrimary.opacity(0.7))
                            .frame(width: max(1, geometry.size.width * fraction))
                    }
                }
                .frame(height: 3)

                if isSelected {
                    Text(detailText)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
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
        }
    }

    /// The other resource is shown alongside the identity: a process at the top
    /// of the CPU list is usually worth checking for memory as well.
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
        }
        return parts.joined(separator: " · ")
    }
}

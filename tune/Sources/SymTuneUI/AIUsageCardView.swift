import SwiftUI
import SymTuneCore
import SymairaTheme

/// The AI-usage card in the status popover.
///
/// One block per enabled provider: meter bars with remaining amount and
/// reset countdown, a sparkline of the usage history, and — crucially — a
/// distinct **unavailable** state ("Source unavailable" + timestamp of
/// the last success) so a failed fetch never masquerades as "0 % used".
@MainActor
struct AIUsageCardView: View {
    let model: AIUsageViewModel

    var body: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                header
                ForEach(model.rows) { row in
                    ProviderRow(row: row)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("AI Usage", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(SymairaTheme.textPrimary)
            Spacer()
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }
}

/// One provider's meters (or its unavailable state).
private struct ProviderRow: View {
    let row: AIUsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SymairaTheme.textPrimary)
                if let source = row.snapshot?.source {
                    Text("via \(source)")
                        .font(.caption2)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
                Spacer()
                if row.isUnavailable {
                    Text("Source unavailable")
                        .font(.caption2)
                        .foregroundStyle(SymairaTheme.critical)
                }
            }

            if let snapshot = row.snapshot {
                meters(snapshot)
            } else {
                unavailableState
            }

            if !row.history.isEmpty {
                SparklineView(
                    samples: row.history,
                    lineColor: SymairaTheme.goldPrimary,
                    showAnnotations: false
                )
                .frame(height: 22)
            }
        }
        .padding(10)
        .background(SymairaTheme.bgCard, in: RoundedRectangle(cornerRadius: 8))
    }

    /// A provider's meters, its balance, or — when it answered with neither
    /// — a line saying so. A successful fetch that yields no meter used to
    /// render as a bare provider name over empty space, which is exactly what
    /// a broken card looks like.
    @ViewBuilder
    private func meters(_ snapshot: AIUsageSnapshot) -> some View {
        ForEach(Array(snapshot.meters.enumerated()), id: \.offset) { _, meter in
            meterRow(meter)
        }
        if let balance = AIUsageFormatting.balanceText(for: snapshot) {
            Text(balance)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(SymairaTheme.textSecondary)
        }
        if let empty = AIUsageFormatting.emptySnapshotText(for: snapshot) {
            Text(empty)
                .font(.caption)
                .foregroundStyle(SymairaTheme.textMuted)
        }
    }

    private func meterRow(_ meter: AIUsageMeter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(meter.label)
                    .font(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                Spacer()
                Text(AIUsageFormatting.remainingText(for: meter))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            if let fraction = AIUsageFormatting.progressFraction(for: meter) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(SymairaTheme.goldPrimary)
            }
            Text("resets in \(AIUsageFormatting.countdownText(until: meter.resetsAt))")
                .font(.caption2)
                .foregroundStyle(SymairaTheme.textMuted)
        }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.error ?? "No data available.")
                .font(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)
                .lineLimit(2)
            if let lastSuccessAt = row.lastSuccessAt {
                Text("Last success: \(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(SymairaTheme.textMuted)
            } else {
                Text("No successful fetch yet")
                    .font(.caption2)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
        }
    }
}

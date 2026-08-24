import SwiftUI
import SymairaTheme
import SymTuneCore

/// Sparkline trends for the enabled system metrics.
///
/// Rows arrive pre-aggregated and pre-formatted from ``TuneViewModel``. The card
/// previously reached into the controller from inside `body`, copying every
/// metric's 120-sample window and recomputing min/max on each evaluation — work
/// that ran again for every slider frame. It is now `Equatable`, so it re-renders
/// only when the numbers themselves change.
struct MetricsHistoryCard: View, Equatable {
    let rows: [MetricRowData]

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 6) {
                HStack {
                    Text("SYSTEM METRICS")
                        .symairaText(.sectionLabel)
                        .foregroundStyle(SymairaTheme.textMuted)
                    Spacer()
                }
                ForEach(rows) { row in
                    MetricsHistoryRow(row: row)
                        .equatable()
                }
            }
            .cardStyle()
        }
    }
}

/// A single metric row: title, current value, sparkline, min/max annotations.
struct MetricsHistoryRow: View, Equatable {
    let row: MetricRowData

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(row.title)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                Spacer()
                Text(row.current)
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTheme.goldSecondary)
                if row.samples.isEmpty {
                    Text("·")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                    Text("collecting…")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }

            if !row.samples.isEmpty {
                SparklineView(samples: row.samples, showAnnotations: true)
                    .equatable()

                HStack {
                    Text("min \(row.minimum)")
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTheme.textMuted)
                    Spacer()
                    Text("max \(row.maximum)")
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }
        }
        .padding(.vertical, SymairaSpacing.xSmall)
    }
}

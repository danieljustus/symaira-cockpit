import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme

/// A passive export of the visible metric selection, with the same values and
/// stale/error state. Rendering never refreshes providers or opens credentials.
@MainActor
struct AIUsageShareCard: View {
    let row: AIUsageRow
    let metrics: [AIUsageMetric]
    let layout: AIUsageLayout
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.displayName).font(.title2.bold())
            if let error = row.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(metric.meter.label)
                        Spacer()
                        Text(metric.displayValue(remaining: layout.remaining)).monospacedDigit()
                    }
                    if let fraction = metric.fraction(remaining: layout.remaining) {
                        ProgressView(value: fraction).progressViewStyle(CockpitProgressStyle())
                    }
                    if let reset = metric.reset(absolute: layout.absoluteReset, now: now) {
                        Text(reset).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !row.history.isEmpty {
                SparklineView(samples: row.history, lineColor: SymairaTokens.selected, showAnnotations: false)
                    .frame(height: 22)
            }
            if let date = row.lastSuccessAt {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Symaira Cockpit").font(.caption.bold()).frame(maxWidth: .infinity)
        }
        .padding(20).frame(width: 420)
        .foregroundStyle(SymairaTokens.ink)
        .background(SymairaTokens.canvas)
    }

    func png(appearance: ColorScheme) -> Data? {
        let renderer = ImageRenderer(content: environment(\.colorScheme, appearance))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

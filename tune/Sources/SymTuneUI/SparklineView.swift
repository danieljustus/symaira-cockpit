import SwiftUI
import SymairaTheme
import SymTuneCore

/// A mini sparkline view that renders a ``MetricSample`` array as a polyline.
///
/// - Value samples are connected by a continuous line.
/// - Gap markers (``MetricSample/isValue == false``) break the line — no
///   fabricated straight line across sleep/wake or unavailable windows.
/// - The Y-axis is auto-scaled to the value range, with optional `min`/`max`
///   annotations.
///
/// `Equatable`, so a redraw only happens when the samples actually change. The
/// drawing pass also computes the range and the min/max annotations in the same
/// walk over the samples instead of the four separate passes it used to do.
struct SparklineView: View, Equatable {
    let samples: [MetricSample]
    let lineColor: Color
    let showAnnotations: Bool

    /// Optional explicit range. When `nil`, the range is computed from the
    /// value samples in `samples`.
    let valueRange: ClosedRange<Double>?

    init(
        samples: [MetricSample],
        lineColor: Color = SymairaTheme.goldPrimary,
        showAnnotations: Bool = true,
        valueRange: ClosedRange<Double>? = nil
    ) {
        self.samples = samples
        self.lineColor = lineColor
        self.showAnnotations = showAnnotations
        self.valueRange = valueRange
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            // Single pass for the extremes.
            var minimum = Double.infinity
            var maximum = -Double.infinity
            var hasValues = false
            for sample in samples {
                guard let value = sample.value else { continue }
                hasValues = true
                if value < minimum { minimum = value }
                if value > maximum { maximum = value }
            }
            guard hasValues else { return }

            let range = valueRange ?? paddedRange(minimum: minimum, maximum: maximum)
            let span = range.upperBound - range.lowerBound
            let scale = span > 0 ? span : 1.0
            let pad: Double = 2
            let denominator = Double(max(1, samples.count - 1))

            func point(index: Int, value: Double) -> CGPoint {
                let x = size.width * Double(index) / denominator
                let normalized = (value - range.lowerBound) / scale
                let y = size.height - pad - (normalized * (size.height - 2 * pad))
                return CGPoint(x: x, y: y)
            }

            // Build the polyline and collect annotation dots in one walk.
            // `pendingStart` holds a segment's first point until a second one
            // arrives, so isolated samples between gaps draw nothing — matching
            // the previous "segments of two or more points" rule.
            var path = Path()
            var pendingStart: CGPoint?
            var inSegment = false
            var annotations: [(point: CGPoint, isMaximum: Bool)] = []

            for (index, sample) in samples.enumerated() {
                guard let value = sample.value else {
                    pendingStart = nil
                    inSegment = false
                    continue
                }

                let position = point(index: index, value: value)
                if let start = pendingStart {
                    path.move(to: start)
                    path.addLine(to: position)
                    pendingStart = nil
                    inSegment = true
                } else if inSegment {
                    path.addLine(to: position)
                } else {
                    pendingStart = position
                }

                if showAnnotations, value == minimum || value == maximum {
                    annotations.append((position, value == maximum))
                }
            }

            context.stroke(
                path,
                with: .color(lineColor),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )

            for annotation in annotations {
                let dot = Path(ellipseIn: CGRect(
                    x: annotation.point.x - 1.5,
                    y: annotation.point.y - 1.5,
                    width: 3,
                    height: 3
                ))
                context.fill(
                    dot,
                    with: .color(annotation.isMaximum ? SymairaTheme.positive : SymairaTheme.warning)
                )
            }
        }
        .frame(height: 22)
    }

    /// Add 10% padding above/below for visual breathing room.
    private func paddedRange(minimum: Double, maximum: Double) -> ClosedRange<Double> {
        if minimum == maximum { return minimum...(minimum + 1) }
        let pad = (maximum - minimum) * 0.1
        return (minimum - pad)...(maximum + pad)
    }
}

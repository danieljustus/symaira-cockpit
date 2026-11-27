import SwiftUI
import SymairaTheme

// Native summary figures (UI catalog E33). The old shared stat tile is
// deprecated in CoreKit 0.25; these two views keep the same reading order,
// typography and VoiceOver value without a custom control.

/// An unbounded figure in a native `LabeledContent` row.
struct CockpitStatValue: View {
    let value: String
    let label: String
    var detail: String? = nil

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .font(SymairaTypography.stat)
                .foregroundStyle(SymairaTokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } label: {
            VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                Text(verbatim: label).symairaText(.secondary)
                if let detail {
                    Text(verbatim: detail).symairaText(.caption).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Self.spoken(value: value, detail: detail))
    }

    static func spoken(value: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return value }
        return "\(value), \(detail)"
    }
}

/// A bounded figure in a native `Gauge` with a spoken current value.
struct CockpitStatGauge: View {
    let value: Double
    let label: String
    let display: String
    var detail: String? = nil

    var body: some View {
        Gauge(value: min(max(value, 0), 100), in: 0...100) {
            Text(verbatim: label)
        } currentValueLabel: {
            Text(verbatim: display)
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(SymairaTokens.selected)
        .accessibilityLabel(label)
        .accessibilityValue(CockpitStatValue.spoken(value: display, detail: detail))
    }
}

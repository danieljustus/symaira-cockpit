import SwiftUI
import SymairaTheme
import SymTuneCore

/// The rendering options for one metric — how it reads in the menu bar and in
/// the System Metrics card — shown beneath its row in Preferences once the
/// metric is monitored.
///
/// "Value" picks amount, percent, or both; "Basis" picks whether that reports
/// what is occupied or what is still free.
///
/// Split out of ``PreferencesView`` to keep that type readable; it is only
/// ever rendered from the metric list there.
struct MetricStyleRow: View {
    @ObservedObject var manager: PreferencesManager
    let metric: MetricIdentifier

    /// What precedes the number, whether it is an amount or a share, and how
    /// much unit suffix it carries — plus a live preview of the result.
    var body: some View {
        let style = manager.style(for: metric)

        return HStack(spacing: 10) {
            stylePicker("Label", selection: style.label) { label in
                switch label {
                case .text: return metric.statusItemLabel
                case .icon: return "Icon"
                case .hidden: return "None"
                }
            }

            stylePicker("Value", selection: style.scale) { scale in
                switch scale {
                case .absolute: return "Amount"
                case .relative: return "Percent"
                case .both: return "Both"
                }
            }
            // CPU is already a percentage and throughput has no total to
            // divide by, so there is nothing for this control to switch.
            .disabled(!metric.supportsRelativeScale)
            .opacity(metric.supportsRelativeScale ? 1 : 0.4)

            stylePicker("Units", selection: style.unit) { unit in
                switch unit {
                case .abbreviated: return "Short"
                case .full: return "Full"
                case .hidden: return "None"
                }
            }

            stylePicker("Basis", selection: style.basis) { basis in
                basis == .used ? "Used" : "Free"
            }
            // CPU and network have no free side to report, so this control is
            // inert for them the same way the Value picker is.
            .disabled(!metric.supportsBasis)
            .opacity(metric.supportsBasis ? 1 : 0.4)

            Spacer()

            Text(preview)
                .symairaText(.monoSmall)
                .foregroundStyle(SymairaTheme.goldPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, SymairaSpacing.section)
    }

    private func stylePicker<Value: Hashable & CaseIterable>(
        _ title: String,
        selection: Binding<Value>,
        label: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.textMuted)
                .lineLimit(1)
                .fixedSize()

            Picker("", selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 86)
        }
    }

    /// What this metric will look like in the menu bar, using a fixed sample
    /// reading (8 GB of 16 GB memory, 256 GB of 512 GB disk) so the preview
    /// does not flicker while the user is reading it.
    private var preview: String {
        MetricStyleFormatting.plainText(
            MetricStyleFormatting.statusItemSegments(
                report: MetricStyleFormatting.sampleReport,
                identifiers: [metric],
                styles: [metric: manager.metricStyles[metric] ?? .default]
            )
        )
    }
}

import SwiftUI
import SymairaTheme
import SymCockpitCore

/// The Cool position's optional "Max avg °C" field, with the live average
/// shown read-only next to it.
///
/// Shown only while Cool is selected: the number applies to no other
/// position, and a field that silently did nothing on Standard or Max would be
/// a lie. Empty means off. The bounds (``FanCoolTarget/range``) are enforced in
/// Core on write and on read; this row refuses an out-of-range entry with a
/// message rather than quietly clamping what the person typed. Owns no logic:
/// every decision is `SymCockpitCore`'s.
struct FanCoolTargetRow: View {
    let controller: TuneController
    let model: TuneViewModel

    @State private var draft = ""
    @State private var message: String?
    @FocusState private var isFocused: Bool

    private var range: ClosedRange<Double> { FanCoolTarget.range }

    private var rangeText: String {
        "\(Int(range.lowerBound))–\(Int(range.upperBound)) °C"
    }

    private var storedText: String {
        model.fanCoolTarget.map { String(Int($0.rounded())) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            HStack(spacing: SymairaSpacing.small) {
                Text("Max avg")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()

                TextField("off", text: $draft)
                    .textFieldStyle(.symaira)
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTokens.ink)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .accessibilityLabel("Cool maximum average temperature in degrees Celsius")
                    .accessibilityHint("Empty turns it off. \(rangeText).")
                    .accessibilityIdentifier("fan-cool-target-field")
                    .help("Adds cooling when the average CPU and GPU cluster temperature "
                          + "nears this value. Leave empty to turn it off. Allowed: \(rangeText).")

                Text("°C")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: SymairaSpacing.small)

                if let average = model.fanAverageClusterCelsius {
                    Text("now \(Int(average.rounded())) °C")
                        .symairaText(.monoSmall)
                        .monospacedDigit()
                        .foregroundStyle(SymairaTokens.ink3)
                        .lineLimit(1)
                        .accessibilityLabel("Current average cluster temperature \(Int(average.rounded())) degrees Celsius")
                }
            }

            if let message {
                Text(message)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Adds cooling near this average CPU/GPU temperature. \(rangeText), empty = off.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = storedText }
        .onChange(of: model.fanCoolTarget) { _, _ in
            // Adopt an externally applied value (CLI, another window), but
            // never overwrite what the person is typing.
            if !isFocused { draft = storedText }
        }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text == storedText { message = nil; return }
        let target: Double?
        if text.isEmpty {
            target = nil
        } else if let whole = Int(text), FanCoolTarget.isWithinRange(Double(whole)) {
            target = Double(whole)
        } else {
            message = "Enter a whole number from \(Int(range.lowerBound)) to \(Int(range.upperBound)), or leave it empty."
            draft = storedText
            return
        }
        message = nil
        let controller = controller
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try controller.setFanCoolTarget(target)
                }.value
                model.refreshNow()
            } catch {
                message = error.localizedDescription
                draft = storedText
            }
        }
    }
}

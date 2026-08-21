import SwiftUI
import SymairaTheme

/// A labelled slider row that owns its drag state.
///
/// Keeping the in-flight value in this view's own `@State` is what makes
/// dragging cheap: only this row's body re-evaluates per drag frame instead of
/// the whole status panel. It also stops the periodic refresh from yanking the
/// knob out from under the user mid-drag, which the previous shared `@State`
/// did every few seconds.
struct TuneSliderRow: View {
    let title: String
    let systemImage: String
    /// Value reported by the model. Adopted whenever it changes externally.
    let value: Double
    let range: ClosedRange<Double>
    var isEnabled: Bool = true
    /// Formats the trailing readout. Defaults to a percentage.
    var format: (Double) -> String = { "\(Int($0 * 100))%" }
    /// Called when the drag ends, with the final value.
    let onCommit: (Double) -> Void

    /// Non-nil once the user has touched the slider, until the model catches up.
    @State private var localValue: Double?
    @State private var isDragging = false

    private var displayedValue: Double { localValue ?? value }

    private var labelColor: Color {
        isEnabled ? SymairaTheme.textSecondary : SymairaTheme.textMuted
    }

    private var readoutColor: Color {
        isEnabled ? SymairaTheme.goldSecondary : SymairaTheme.textMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .symairaText(.caption)
                    .foregroundStyle(labelColor)
                Spacer()
                Text(format(displayedValue))
                    .symairaText(.monoSmall)
                    .foregroundStyle(readoutColor)
            }
            Slider(
                value: Binding(
                    get: { displayedValue },
                    set: { localValue = $0 }
                ),
                in: range,
                onEditingChanged: { editing in
                    isDragging = editing
                    guard !editing, let final = localValue else { return }
                    onCommit(final)
                }
            )
            .tint(SymairaTheme.goldPrimary)
            .disabled(!isEnabled)
        }
        .onChange(of: value) { _, _ in
            // Adopt an externally applied value, but never fight an active drag.
            guard !isDragging else { return }
            localValue = nil
        }
    }
}

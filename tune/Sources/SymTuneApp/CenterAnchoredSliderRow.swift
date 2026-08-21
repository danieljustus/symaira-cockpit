import SwiftUI
import SymairaTheme
import SymTuneCore

/// A slider anchored at its middle, where centre means "no change".
///
/// Same drag-state ownership as ``TuneSliderRow`` — the in-flight value stays
/// local so a drag re-renders this row only and the periodic refresh cannot
/// yank the knob mid-gesture. What it adds is the centre: a tick under the
/// midpoint and end labels, so the control reads as a deviation from normal
/// rather than as an absolute level.
struct CenterAnchoredSliderRow: View {
    let title: String
    let systemImage: String
    /// Position reported by the model, in ``BeyondNormalBrightness/positionRange``.
    let position: Double
    /// Labels under the two ends, e.g. "Darker" / "Brighter".
    let minimumLabel: String
    let maximumLabel: String
    /// Trailing readout for the current position.
    var format: (Double) -> String = BeyondNormalBrightness.readout(position:)
    /// Set when the positive half cannot do anything on this display.
    var maximumDisabledNote: String?
    let onCommit: (Double) -> Void

    @State private var localPosition: Double?
    @State private var isDragging = false

    private var displayed: Double { localPosition ?? position }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                Spacer()
                Text(format(displayed))
                    .symairaText(.monoSmall)
                    .foregroundStyle(
                        abs(displayed) < 0.005
                            ? SymairaTheme.textMuted
                            : SymairaTheme.goldSecondary
                    )
            }

            ZStack(alignment: .center) {
                // The centre detent, drawn behind the track: the one position
                // that means "symtune is doing nothing to this display".
                Rectangle()
                    .fill(SymairaTheme.goldPrimary.opacity(0.35))
                    .frame(width: 1, height: 12)

                Slider(
                    value: Binding(
                        get: { displayed },
                        set: { localPosition = snapToCentre($0) }
                    ),
                    in: BeyondNormalBrightness.positionRange,
                    onEditingChanged: { editing in
                        isDragging = editing
                        guard !editing, let final = localPosition else { return }
                        onCommit(final)
                    }
                )
                .tint(SymairaTheme.goldPrimary)
            }

            HStack {
                Text(minimumLabel)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text("Normal")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text(maximumDisabledNote ?? maximumLabel)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .onChange(of: position) { _, _ in
            guard !isDragging else { return }
            localPosition = nil
        }
    }

    /// Getting back to exactly normal matters more here than fine control near
    /// the middle, and a continuous slider makes hitting 0 by hand fiddly.
    private func snapToCentre(_ value: Double) -> Double {
        abs(value) < 0.04 ? 0 : value
    }
}

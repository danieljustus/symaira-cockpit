import SwiftUI
import SymairaTheme

// Compatibility names for existing cards; the palette and renderer have one
// implementation in AppKit, shared with every native Symaira consumer.
typealias CockpitBarColors = SymairaBarColors

/// The neutral rail of the native `ProgressView(value:)` meters (E19). The
/// fill is shared with `EffortSliderCell`, so both controls read the same.
struct CockpitProgressStyle: ProgressViewStyle {
    let height: CGFloat

    init(height: CGFloat = 8) { self.height = height }

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(CockpitBarColors.track)
                Capsule().fill(CockpitBarColors.fill)
                    .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
                Capsule().strokeBorder(CockpitBarColors.trackOutline, lineWidth: 1)
            }
        }
        .frame(height: height)
    }
}

import SwiftUI
import SymTuneCore

/// Same production slider row in the live fan card and passive design preview.
/// Detents select existing thermal curves, never arbitrary or unclamped RPM.
struct FanProfileSliderRow: View {
    let profile: FanProfile
    var isEnabled = true
    let onCommit: (FanProfile) -> Void

    var body: some View {
        TuneSliderRow(
            title: "Fan Profile",
            systemImage: "fanblades.fill",
            value: Double(profile.step),
            range: 0...Double(FanProfile.ordered.count - 1),
            isEnabled: isEnabled,
            tickCount: FanProfile.ordered.count,
            snapsToTicks: true,
            format: { FanProfile.at(step: Int($0.rounded())).displayName },
            onCommit: { position in
                let next = FanProfile.at(step: Int(position.rounded()))
                guard next != profile else { return }
                onCommit(next)
            }
        )
    }
}

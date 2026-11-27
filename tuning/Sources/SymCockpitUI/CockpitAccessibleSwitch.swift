import SwiftUI
import SymairaTheme

/// The native macOS switch (E08) with the Symaira selection tint and the
/// product's existing VoiceOver name, which is longer than the visible title.
///
/// The hosted NSSwitch does not carry a SwiftUI accessibility label into the
/// AppKit tree, so the switch is presented as one SwiftUI accessibility element
/// with the name, the on/off value, the toggle trait and the press action.
struct CockpitAccessibleSwitch: View {
    let title: String
    let accessibilityLabel: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .tint(SymairaTokens.selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction { isOn.toggle() }
    }
}

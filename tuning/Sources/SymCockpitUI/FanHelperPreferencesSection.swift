import SwiftUI
import SymairaTheme
import SymCockpitCore

/// Preferences section for the optional privileged fan helper (issue #405).
struct FanHelperPreferencesSection: View {
    @ObservedObject var preferences: FanHelperPreferences
    /// Why the user landed here (they tried to change fan speed without the
    /// rights for it); nil when they navigated here themselves.
    var hint: String?
    /// Called once the helper is enabled, so the hint does not outlive its cause.
    var onHintResolved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRIVILEGED FAN HELPER")
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTokens.ink3)

            if let hint {
                Text(hint)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-helper-hint")
            }

            Text("An optional background helper, registered with macOS, that applies fan changes without asking for your administrator password and does not depend on a root-owned copy of the command-line tool. It only accepts requests from this app, never lifts the Mac's thermal protection, and hands the fans back to the system curve if the app stops responding. You can remove it here at any time.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle(isOn: Binding(
                    get: { preferences.isOptedIn },
                    set: { preferences.setOptedIn($0) }
                )) {
                    Text("Use the privileged helper for fan control")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink)
                }
                .toggleStyle(.symairaSwitch)
                .disabled(!preferences.canEnable || preferences.isWorking)
                .accessibilityIdentifier("fan-helper-toggle")
                Spacer()
            }

            Text(preferences.statusLine)
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
                .fixedSize(horizontal: false, vertical: true)

            if let message = preferences.message {
                Text(message)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preferences.needsApproval {
                Button("Open System Settings…") { preferences.openSystemSettings() }
                    .accessibilityIdentifier("fan-helper-open-settings")
            }
        }
        .onAppear { preferences.refresh() }
        .onChange(of: preferences.availability) { _, availability in
            if availability == .enabled { onHintResolved() }
        }
    }
}

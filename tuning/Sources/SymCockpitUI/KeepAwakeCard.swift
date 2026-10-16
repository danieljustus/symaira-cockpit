import SwiftUI
import SymairaTheme
import SymCockpitCore

/// Keep Awake session card: status indicator, duration picker, display-sleep
/// toggle, and start/end button. Extracted from MainStatusView to keep the
/// main view under the type-body-length limit.
struct KeepAwakeCard: View {
    /// Whether a keep-awake session is currently active. Owned by the model —
    /// the card reports intent through `onToggle` and re-reads the result.
    let active: Bool
    /// Whether to prevent display sleep in addition to system sleep.
    @Binding var preventDisplaySleep: Bool
    /// Selected duration preset index (0 = indefinite).
    @Binding var durationIndex: Int
    /// Human-readable remaining time, or nil.
    let remaining: String?
    /// Whether the session controls should be interactive.
    let isInteractive: Bool
    /// Duration presets: (label, seconds).
    let presets: [(label: String, seconds: TimeInterval?)]
    /// Called when the start/end button is pressed.
    let onToggle: () -> Void
    @Environment(\.tunePanelChrome) private var chrome

    var body: some View {
        VStack(spacing: SymairaSpacing.small) {
            HStack {
                Label("Keep Awake", systemImage: active ? "lock.fill" : "lock.open.fill")
                    .symairaText(.subheading)
                    .foregroundStyle(active ? SymairaTokens.selected : SymairaTokens.ink2)
                Spacer()
                // Status indicator
                Circle()
                    .fill(active ? SymairaTokens.positive : SymairaTokens.critical.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(active ? "Active" : "Inactive")
                    .symairaText(.caption)
                    .foregroundStyle(active ? SymairaTokens.positive : SymairaTokens.ink3)
                if active, let remaining = remaining {
                    Text("· \(remaining)")
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTokens.ink)
                }
            }

            HStack(spacing: SymairaSpacing.small) {
                Text("Duration")
                    .symairaText(chrome == .embedded ? .callout : .caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink2)
                Spacer()
                Picker("Duration", selection: $durationIndex) {
                    ForEach(0..<presets.count, id: \.self) { i in
                        Text(presets[i].label).tag(i)
                    }
                }
                .labelsHidden()
                .disabled(!isInteractive)
            }

            Toggle("Keep display awake", isOn: $preventDisplaySleep)
                .symairaText(chrome == .embedded ? .callout : .caption, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink2)
                .toggleStyle(.symairaSwitch)
                .disabled(!isInteractive)
                .accessibilityLabel("Keep display awake")
                .help("The Mac stays awake during the session. Enable this to also prevent display sleep.")

            // Start / End button
            sessionButton
        }
        .cardStyle(
            borderColor: active
                ? SymairaTokens.ink3
                : SymairaTokens.line
        )
    }

    var sessionButton: some View {
        Button(action: onToggle) {
            Text(active ? "End Session" : "Start Session")
                .frame(maxWidth: .infinity)
        }
        .symairaButtonStyle(active ? .secondary : .primary)
        .accessibilityIdentifier("cockpit-keep-awake-session")
    }
}

import SwiftUI
import SymairaTheme
import SymTuneCore

/// The AI-usage block of the preferences window: per-provider toggles
/// (default off — no network calls until enabled), provider-specific
/// credential UI (API-key SecureFields or external-auth state), and the
/// menu-bar readout toggle + refresh interval.
///
/// Extracted from ``PreferencesView`` to keep that file under the line cap.
struct AIUsagePreferencesSection: View {
    @ObservedObject var preferences: AIUsagePreferences
    let providers: [any AIUsageProvider]
    /// Called after a credential is saved or cleared, so the caller can drop
    /// the AI-usage cache and refresh immediately (issue #324).
    let onCredentialChange: () -> Void

    private func binding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(providerID) },
            set: { preferences.setEnabled(providerID, $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Usage")
                .symairaText(.subheading)
                .foregroundStyle(SymairaTheme.textPrimary)

            Text("Track AI subscription usage per provider. Disabled providers make no network calls; credentials live in the Keychain, never in config.toml.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)

            ForEach(providers, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: binding(for: provider.id)) {
                        Text(provider.displayName)
                            .symairaText(.body)
                            .foregroundStyle(SymairaTheme.textPrimary)
                    }
                    .tint(SymairaTheme.goldPrimary)

                    if preferences.isEnabled(provider.id) {
                        ProviderCredentialView(
                            provider: provider,
                            preferences: preferences,
                            onCredentialChange: onCredentialChange
                        )
                        .id(provider.id)
                    }
                }
            }

            // Display options (issue #361)
            if preferences.menuBarEnabled {
                displayOptionsSection
            }

            Toggle(isOn: $preferences.menuBarEnabled) {
                Text("Show AI usage in the menu bar")
                    .symairaText(.body)
                    .foregroundStyle(SymairaTheme.textPrimary)
            }
            .tint(SymairaTheme.goldPrimary)

            HStack {
                Text("Refresh interval")
                    .symairaText(.body)
                    .foregroundStyle(SymairaTheme.textPrimary)
                Spacer()
                Picker("", selection: $preferences.refreshInterval) {
                    ForEach(AIUsagePreferences.intervalOptions, id: \.self) { interval in
                        Text("\(Int(interval / 60)) min").tag(interval)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Display options (issue #361)

    @ViewBuilder
    private var displayOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textSecondary)

            Toggle("Pin active provider to menu bar", isOn: $preferences.displayPinnedProvider)
                .tint(SymairaTheme.goldPrimary)
            Toggle("Reorder providers by drag", isOn: $preferences.displayAllowReorder)
                .tint(SymairaTheme.goldPrimary)
            Toggle("Hide unconfigured providers", isOn: $preferences.displayHideUnconfigured)
                .tint(SymairaTheme.goldPrimary)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Provider credential view (issue #360)

/// Renders the credential input/state for a single provider based on its
/// `credentialDescriptor`. API-key providers get an APIKeyField; external-token
/// providers get a live auth-state row with a re-auth hint.
struct ProviderCredentialView: View {
    let provider: any AIUsageProvider
    @ObservedObject var preferences: AIUsagePreferences
    let onCredentialChange: () -> Void

    var body: some View {
        if let descriptor = provider.credentialDescriptor {
            switch descriptor.authKind {
            case .apiKey(let account):
                let field = Self.apiKeyField(for: provider.id)
                let label = field?.label ?? "\(provider.displayName) API key"
                let placeholder = field?.placeholder ?? "sk-…"
                APIKeyField(
                    providerID: provider.id,
                    accountId: account,
                    label: label,
                    placeholder: placeholder,
                    onCredentialChange: onCredentialChange
                )

            case .externalToken(let resolver):
                ExternalAuthStateRow(
                    providerID: provider.id,
                    descriptor: descriptor,
                    resolver: resolver
                ) {
                    onCredentialChange()
                }

            case .multi(let kinds):
                VStack(alignment: .leading, spacing: 4) {
                    ExternalAuthStateRow(
                        providerID: provider.id,
                        descriptor: descriptor,
                        resolver: .init(read: { ExternalAuthState(status: .missing, detail: "Not configured", source: nil) })
                    ) {
                        onCredentialChange()
                    }
                    Text("Supported sources: \(kinds.map { kindLabel($0) }.joined(separator: ", "))")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textSecondary)
                }
            }
        } else {
            // No credential descriptor — the provider auto-detects or uses
            // env vars. Show an informational hint.
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(SymairaTheme.textSecondary)
                Text("\(provider.displayName) auto-detects credentials or reads environment variables.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            .padding(.leading, 20)
        }
    }

    // MARK: - Helpers

    /// Providers whose credentials are plain API keys stored in the Keychain.
    private static func apiKeyField(for providerID: String) -> (label: String, placeholder: String)? {
        switch providerID {
        case "moonshot":
            return ("Moonshot API key", "sk-…")
        case "openrouter":
            return ("OpenRouter API key", "sk-or-…")
        case "kimi":
            return ("Kimi Code API key", "kimi-…")
        default:
            return nil
        }
    }

    private func kindLabel(_ kind: AIUsageCredentialDescriptor.AuthKind) -> String {
        switch kind {
        case .apiKey: return "API key"
        case .externalToken: return "External OAuth/CLI"
        case .multi: return "Multiple"
        }
    }
}

// MARK: - External auth state row (issue #360)

/// Shows the auth state of a provider whose credentials come from an external
/// CLI/OAuth flow, with a re-auth hint when missing or partial.
struct ExternalAuthStateRow: View {
    let providerID: String
    let descriptor: AIUsageCredentialDescriptor
    let resolver: AIUsageCredentialDescriptor.ExternalTokenResolver
    let onRefresh: () -> Void

    /// Cached auth state — refreshed on appear and after explicit refresh.
    @State private var authState: ExternalAuthState?
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.sourceLabel)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textPrimary)

                if let detail = authState?.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(SymairaTheme.textSecondary)
                }
            }

            Spacer()

            if let state = authState {
                statusBadge(for: state.status)
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(SymairaTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Refresh auth state")
        }
        .padding(.leading, 20)
        .onAppear { refresh() }
    }

    private func refresh() {
        isLoading = true
        Task {
            authState = resolver.read()
            isLoading = false
            onRefresh()
        }
    }

    private var iconName: String {
        switch authState?.status ?? .missing {
        case .available: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.circle"
        case .expired: return "clock.badge.xmark"
        case .partial: return "exclamationmark.octagon"
        }
    }

    private var iconColor: Color {
        switch authState?.status ?? .missing {
        case .available: return Color.green
        case .missing: return Color.red
        case .expired: return Color.orange
        case .partial: return Color.orange
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ExternalAuthState.Status) -> some View {
        switch status {
        case .available:
            Text("Ready")
                .font(.caption2).bold()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.green)
        default:
            Text(status == .partial ? "Partial" : (status == .expired ? "Expired" : "Missing"))
                .font(.caption2).bold()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.red.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.red)
        }
    }
}

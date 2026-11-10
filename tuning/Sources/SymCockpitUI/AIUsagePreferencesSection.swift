import SwiftUI
import SymairaProviderKit
import SymairaTheme
import SymCockpitCore

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
                .foregroundStyle(SymairaTokens.ink)

            Text("""
                Track AI subscription usage per provider. Symbrain owns provider discovery, auth status, and credential resolution; \
                API keys entered here are stored in SymVault, never in config.toml or cockpit's Keychain.
                """)
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink2)

            ForEach(providers.filter {
                AIUsageVisibility.isVisible(hideUnconfigured: preferences.displayHideUnconfigured,
                    isEnabled: preferences.isEnabled($0.id), isConfigured: $0.isConfigured)
            }, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: binding(for: provider.id)) {
                        HStack(spacing: 6) {
                            Text(provider.displayName)
                                .symairaText(.body)
                                .foregroundStyle(SymairaTokens.ink)
                            Text(provider.isConfigured ? "Configured" : "Not configured")
                                .symairaText(.caption)
                                .foregroundStyle(SymairaTokens.ink2)
                        }
                    }
                    .tint(SymairaTokens.selected)

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

            displayOptionsSection

            HStack {
                Text("Refresh interval")
                    .symairaText(.body)
                    .foregroundStyle(SymairaTokens.ink)
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
                .foregroundStyle(SymairaTokens.ink2)

            AIUsageDisplayControls(preferences: preferences)
            Toggle("Use first metric when no stars are set", isOn: $preferences.displayPinnedProvider)
                .tint(SymairaTokens.selected)
            Toggle("Reorder providers by drag", isOn: $preferences.displayAllowReorder)
                .tint(SymairaTokens.selected)
            Toggle("Hide unconfigured providers", isOn: $preferences.displayHideUnconfigured)
                .tint(SymairaTokens.selected)
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
            case .apiKey:
                // The shared credential field stores under
                            // "<providerID>-api-key" in the given keychain service —
                            // the same slot convention the previous local field used,
                            // so existing stored keys keep working (issue #42).
                Text(descriptor.sourceLabel)
                    .font(SymairaTypography.caption)
                    .padding(.leading, 20)
                let field = Self.apiKeyField(for: provider.id)
                SymVaultCredentialField(
                    providerID: provider.id,
                    store: SymVaultCredentialStore(),
                    title: field?.label ?? "\(provider.displayName) API key",
                    preferences: preferences,
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
                        .foregroundStyle(SymairaTokens.ink2)
                }
            }
        } else {
            // No credential descriptor — the provider auto-detects or uses
            // env vars. Show an informational hint.
            HStack {
                SymairaIconView(.info, size: 14)
                    .foregroundStyle(SymairaTokens.ink2)
                Text("\(provider.displayName) auto-detects credentials or reads environment variables.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink2)
            }
            .padding(.leading, 20)
        }
    }

    // MARK: - Helpers

    /// Providers whose credentials are plain API keys stored in the Keychain.
    private static func apiKeyField(for providerID: String) -> (label: String, placeholder: String)? {
        switch providerID {
        case "zai":
            return ("Z.ai API key", "")
        case "devin":
            return ("Codeium-compatible Devin CLI credential", "")
        case "grok":
            return ("Grok access token", "")
        case "opencode":
            return ("OpenCode Go API key (optional)", "")
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
            SymairaIconView(icon, size: 16)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.sourceLabel)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink)

                if let detail = authState?.detail {
                    Text(detail)
                        .font(SymairaTypography.caption)
                        .foregroundStyle(SymairaTokens.ink2)
                }
            }

            Spacer()

            if let state = authState {
                statusBadge(for: state.status)
            }

            SymairaIconButton("Refresh auth state", icon: .refresh, size: 14, action: refresh)
                .foregroundStyle(SymairaTokens.ink2)
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

    private var icon: SymairaIcon {
        switch authState?.status ?? .missing {
        case .available: return .success
        case .missing: return .warning
        case .expired: return .time
        case .partial: return .error
        }
    }

    private var iconColor: Color {
        switch authState?.status ?? .missing {
        case .available: return SymairaTokens.positive
        case .missing: return SymairaTokens.critical
        case .expired: return SymairaTokens.warning
        case .partial: return SymairaTokens.warning
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ExternalAuthState.Status) -> some View {
        switch status {
        case .available:
            Text("Ready")
                .font(SymairaTypography.micro)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(SymairaTokens.positive.opacity(0.15), in: Capsule())
                .foregroundStyle(SymairaTokens.positive)
        default:
            Text(status == .partial ? "Partial" : (status == .expired ? "Expired" : "Missing"))
                .font(SymairaTypography.micro)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(SymairaTokens.critical.opacity(0.15), in: Capsule())
                .foregroundStyle(SymairaTokens.critical)
        }
    }
}

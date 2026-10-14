import Foundation

/// One catalog entry backed by symbrain's provider report. The shared state is
/// updated after each report so Preferences reflects the command's configured
/// status rather than reimplementing credential discovery locally.
public final class SymBrainUsageProvider: AIUsageProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let credentialDescriptor: AIUsageCredentialDescriptor?
    private let state: State

    public var isConfigured: Bool { state.configured }
    public var authState: ExternalAuthState { state.authState }
    public var credentialSource: String { authState.source ?? "none" }

    public init(
        id: String,
        displayName: String,
        credentialDescriptor: AIUsageCredentialDescriptor? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.state = State()
        self.credentialDescriptor = credentialDescriptor ?? Self.defaultDescriptor(for: id, state: state)
    }

    func update(from row: SymBrainProviderUsage) {
        state.update(configured: row.configured, authStatus: row.authStatus)
    }

    /// Catalog order is the stable order used by the old CLI/MCP responses and
    /// by the existing Preferences toggles.
    public static func catalog() -> [SymBrainUsageProvider] {
        [
            SymBrainUsageProvider(id: "claude", displayName: "Claude"),
            SymBrainUsageProvider(id: "codex", displayName: "Codex"),
            SymBrainUsageProvider(id: "copilot", displayName: "GitHub Copilot"),
            SymBrainUsageProvider(id: "cursor", displayName: "Cursor"),
            SymBrainUsageProvider(id: "kimi", displayName: "Kimi Code"),
            SymBrainUsageProvider(id: "moonshot", displayName: "Moonshot"),
            SymBrainUsageProvider(id: "nous", displayName: "Nous Portal"),
            SymBrainUsageProvider(id: "opencode", displayName: "OpenCode Go"),
            SymBrainUsageProvider(id: "openrouter", displayName: "OpenRouter"),
            SymBrainUsageProvider(id: "antigravity", displayName: "Antigravity"),
        ]
    }

    private static func defaultDescriptor(
        for id: String,
        state: State
    ) -> AIUsageCredentialDescriptor? {
        let account: String?
        let label: String
        switch id {
        case "moonshot":
            account = "moonshot-api-key"
            label = "API key (symbrain env MOONSHOT_API_KEY or Keychain)"
        case "openrouter":
            account = "openrouter-api-key"
            label = "API key (symbrain env OPENROUTER_API_KEY or Keychain)"
        case "kimi":
            account = "kimi-api-key"
            label = "API key (symbrain env KIMI_CODE_API_KEY or Keychain)"
        case "claude":
            account = nil
            label = "Claude Code OAuth (managed by symbrain)"
        case "codex":
            account = nil
            label = "Codex CLI OAuth (managed by symbrain)"
        case "copilot":
            account = nil
            label = "GitHub Copilot auth (managed by symbrain)"
        case "cursor":
            account = nil
            label = "Cursor auth (managed by symbrain)"
        case "nous":
            account = nil
            label = "Hermes auth store (managed by symbrain)"
        case "opencode":
            account = nil
            label = "OpenCode auth (managed by symbrain)"
        case "antigravity":
            account = nil
            label = "Local Antigravity probe (managed by symbrain)"
        default:
            account = nil
            label = "Authentication (managed by symbrain)"
        }

        if let account {
            return AIUsageCredentialDescriptor(authKind: .apiKey(account: account), sourceLabel: label)
        }
        return AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { state.authState })),
            sourceLabel: label
        )
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedConfigured = false
        private var storedAuthState = ExternalAuthState(status: .missing, detail: "Not checked yet", source: nil)

        var configured: Bool {
            lock.withLock { storedConfigured }
        }

        var authState: ExternalAuthState {
            lock.withLock { storedAuthState }
        }

        func update(configured: Bool, authStatus: SymBrainAuthStatus) {
            let status: ExternalAuthState.Status
            switch authStatus.status {
            case "available": status = .available
            case "expired": status = .expired
            case "partial": status = .partial
            default: status = .missing
            }
            let authState = ExternalAuthState(
                status: status,
                detail: authStatus.detail,
                source: authStatus.source
            )
            lock.withLock {
                storedConfigured = configured
                storedAuthState = authState
            }
        }
    }
}

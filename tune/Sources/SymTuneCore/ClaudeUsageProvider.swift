import Foundation
import Security

// MARK: - Keychain prompt policy

/// Whether the Claude provider may trigger interactive Keychain prompts.
/// Default is ``never``: background reads must never pop a dialog.
public enum KeychainPromptPolicy: String, Sendable, CaseIterable {
    case never
    case onlyOnUserAction
    case always

    /// Background reads never pop a dialog.
    public static let `default` = KeychainPromptPolicy.never

    public var label: String {
        switch self {
        case .never: return "Never prompt"
        case .onlyOnUserAction: return "Only on user action"
        case .always: return "Always allow prompts"
        }
    }
}

// MARK: - Claude provider

/// Claude usage provider.
///
/// Fallback chain:
/// 1. **Admin API key** (`api`) — Keychain, fallback `ANTHROPIC_ADMIN_KEY`;
///    queries the organization cost/usage reports.
/// 2. **OAuth** (`oauth`) — token from the Keychain entry
///    `Claude Code-credentials`, file fallback `~/.claude/.credentials.json`;
///    queries `GET /api/oauth/usage` (session + weekly windows).
///
/// Known pitfall: on Claude Code 2.1.x the Keychain entry can contain only
/// MCP-OAuth state (`mcpOAuth`) without `claudeAiOauth`. That is treated as
/// a **configuration error** (re-auth hint), never as an empty quota.
public struct ClaudeUsageProvider: AIUsageProvider, Sendable {
    public let id = "claude"
    public let displayName = "Claude"

    public var isConfigured: Bool {
        strategies.contains { $0.source == "api" } || strategies.contains { $0.source == "oauth" }
    }

    public var strategies: [any AIUsageStrategy] {
        var result: [any AIUsageStrategy] = []
        if !adminKey.isEmpty {
            result.append(ClaudeAdminAPIStrategy(apiKey: adminKey, network: network))
        }
        if oauthToken != nil {
            result.append(ClaudeOAuthStrategy(
                accessToken: oauthToken!,
                network: network
            ))
        }
        return result
    }

    private let adminKey: String
    private let oauthToken: String?
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - adminAPIKey: explicit admin key; defaults to Keychain lookup with
    ///     `ANTHROPIC_ADMIN_KEY` fallback.
    ///   - oauthToken: explicit OAuth token; defaults to the Keychain entry
    ///     `Claude Code-credentials` / `~/.claude/.credentials.json`.
    ///   - keychainPromptPolicy: when interactive Keychain prompts are
    ///     allowed (default ``never`` — background reads never pop a dialog).
    ///   - network: injectable network seam for tests.
    ///   - oauthTokenReader: injectable credential reader (test seam); the
    ///     default reads the real Keychain/file sources.
    public init(
        adminAPIKey: String? = nil,
        oauthToken: String? = nil,
        keychainPromptPolicy: KeychainPromptPolicy = .never,
        network: any NetworkServiceProtocol = URLSessionNetworkService(),
        oauthTokenReader: (@Sendable (KeychainPromptPolicy) -> String?)? = nil
    ) {
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"]
        let keychainKey = KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: "anthropic-admin-key"
        )
        self.adminKey = adminAPIKey ?? envKey ?? keychainKey ?? ""

        if let explicit = oauthToken {
            self.oauthToken = explicit.isEmpty ? nil : explicit
        } else if let reader = oauthTokenReader {
            self.oauthToken = reader(keychainPromptPolicy)
        } else {
            self.oauthToken = ClaudeOAuthCredentials.read(
                keychainPromptPolicy: keychainPromptPolicy
            )
        }
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .multi([
                .apiKey(account: "anthropic-admin-key"),
                .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            ]),
            sourceLabel: "Admin API key (ANTHROPIC_ADMIN_KEY) or Claude Code OAuth"
        )
    }

    /// Reads the Claude auth state for the preferences UI — side-effect-free.
    static func readExternalAuthState() -> ExternalAuthState {
        let token = ClaudeOAuthCredentials.read(keychainPromptPolicy: .never)
        if let token, !token.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via Claude Code OAuth token",
                source: "oauth"
            )
        }
        // Check for the known pitfall: Keychain entry with MCP-OAuth only.
        if ClaudeOAuthCredentials.keychainEntryExists() {
            return ExternalAuthState(
                status: .partial,
                detail: "Keychain entry holds only MCP OAuth state — re-auth with the Claude CLI",
                source: "keychain"
            )
        }
        // Check file fallback.
        if let fileToken = ClaudeOAuthCredentials.fileToken() {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via Claude Code OAuth token (file)",
                source: "file"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Claude credentials found — add an admin key or sign in with the Claude CLI",
            source: nil
        )
    }
}

// MARK: - OAuth credentials

enum ClaudeOAuthCredentials {
    /// Reads the Claude OAuth token without triggering an interactive
    /// Keychain prompt (policy-gated). Sources, in order:
    /// 1. Keychain entry `Claude Code-credentials` (`claudeAiOauth` field).
    /// 2. File `~/.claude/.credentials.json` (`oauthAccount` tokens).
    /// Returns `nil` when no usable OAuth token exists.
    static func read(keychainPromptPolicy: KeychainPromptPolicy) -> String? {
        if let fromKeychain = keychainToken(policy: keychainPromptPolicy) {
            return fromKeychain
        }
        return fileToken()
    }

    /// Returns true when a Keychain entry for `Claude Code-credentials`
    /// exists at all — used to detect the MCP-OAuth-only partial state.
    static func keychainEntryExists() -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Reads `claudeAiOauth` from the `Claude Code-credentials` Keychain
    /// entry. When the entry exists but carries only `mcpOAuth` state, a
    /// config error is reported as a re-auth hint instead of an empty quota.
    static func keychainToken(policy: KeychainPromptPolicy) -> String? {
        // Respect the prompt policy: only read non-interactively when the
        // policy forbids prompts. kSecUseOperationPrompt is only attached
        // when the policy allows it.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if policy == .always || policy == .onlyOnUserAction {
            query[kSecUseOperationPrompt as String] = "symtune reads Claude usage"
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        // mcpOAuth without claudeAiOauth → configuration error (re-auth).
        if json["mcpOAuth"] != nil {
            return nil
        }
        return nil
    }

    /// File fallback: `~/.claude/.credentials.json` OAuth accounts.
    static func fileToken() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["oauthAccount"] as? [String: Any]
        else { return nil }
        // Prefer the "default" account, then any account with an access token.
        if let def = accounts["default"] as? [String: Any],
           let token = def["accessToken"] as? String, !token.isEmpty {
            return token
        }
        for (_, account) in accounts {
            if let entry = account as? [String: Any],
               let token = entry["accessToken"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }
}

// MARK: - Admin API strategy

/// Organization-level spend/usage via the Anthropic Admin API.
public struct ClaudeAdminAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let apiKey: String
    private let network: any NetworkServiceProtocol

    public init(apiKey: String, network: any NetworkServiceProtocol) {
        self.apiKey = apiKey
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        // `/v1/organizations/cost_report` with `?bucket_width=1d&limit=7`
        let base = URL(string: "https://api.anthropic.com")!
        let endpoint = base
            .appendingPathComponent("v1")
            .appendingPathComponent("organizations")
            .appendingPathComponent("cost_report")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "7"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("claude", retryAfter: retryAfterSeconds(from: http))
            }
            throw ClaudeError.httpStatus(http.statusCode)
        }

        let payload: ClaudeCostReport
        do {
            payload = try JSONDecoder().decode(ClaudeCostReport.self, from: data)
        } catch {
            throw ClaudeError.unparseable
        }

        var meters: [AIUsageMeter] = []
        if let total = payload.totalCostUSD {
            meters.append(AIUsageMeter(
                label: "Spend (7d)",
                used: Decimal(total),
                limit: nil,
                unit: .currency("USD")
            ))
        }
        if let messages = payload.totalMessages {
            meters.append(AIUsageMeter(
                label: "Messages (7d)",
                used: Decimal(messages),
                limit: nil,
                unit: .requests
            ))
        }

        return AIUsageSnapshot(
            providerID: "claude",
            meters: meters,
            balance: nil,
            currency: "USD",
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - OAuth strategy

/// Session + weekly quota via the Claude OAuth usage API.
public struct ClaudeOAuthStrategy: AIUsageStrategy, Sendable {
    public let source = "oauth"

    private let accessToken: String
    private let network: any NetworkServiceProtocol

    public init(accessToken: String, network: any NetworkServiceProtocol) {
        self.accessToken = accessToken
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("claude", retryAfter: retryAfterSeconds(from: http))
            }
            throw ClaudeError.httpStatus(http.statusCode)
        }

        let payload: ClaudeOAuthUsage
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(ClaudeOAuthUsage.self, from: data)
        } catch {
            throw ClaudeError.unparseable
        }

        var meters: [AIUsageMeter] = []
        // Session window (5h) and weekly window (7d) as separate meters.
        for window in [payload.fiveHour, payload.sevenDay].compactMap({ $0 }) {
            guard let limit = window.limit, limit > 0 else { continue }
            meters.append(AIUsageMeter(
                label: window.windowName,
                used: Decimal(window.utilized ?? 0),
                limit: Decimal(limit),
                unit: .percent,
                resetsAt: window.resetsAt
            ))
        }
        if let extra = payload.extraUsage {
            meters.append(AIUsageMeter(
                label: "Extra usage",
                used: extra.used.map { Decimal($0) },
                limit: extra.limit.map { Decimal($0) },
                unit: .currency("USD")
            ))
        }

        return AIUsageSnapshot(
            providerID: "claude",
            meters: meters,
            balance: nil,
            currency: "USD",
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response models

struct ClaudeCostReport: Decodable {
    let totalCostUSD: Double?
    let totalMessages: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case totalCostUSD = "total_cost_usd"
        case totalMessages = "total_messages"
        case totalTokens = "total_tokens"
    }
}

struct ClaudeOAuthUsage: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case extraUsage = "extra_usage"
    }
}

struct ClaudeUsageWindow: Decodable {
    /// Display label ("five_hour" / "seven_day"), derived from the JSON key.
    let windowName: String
    let utilized: Double?
    let limit: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case windowName
        case utilized
        case limit
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilized = try container.decodeIfPresent(Double.self, forKey: .utilized)
        limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        // The window name is the enclosing JSON key (five_hour / seven_day),
        // not a field of the window object itself.
        windowName = decoder.codingPath.last?.stringValue ?? "window"
    }
}

struct ClaudeExtraUsage: Decodable {
    let used: Double?
    let limit: Double?
}

// MARK: - Rate limit parsing

/// Parses the `Retry-After` header's delta-seconds form (e.g. `"30"`);
/// `nil` when the header is absent or not a plain integer/decimal — the
/// HTTP-date form is not handled since 429 responses conventionally use
/// delta-seconds.
private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    return TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Errors

enum ClaudeError: Error, LocalizedError {
    case network(String)
    case invalidResponse
    case httpStatus(Int)
    case unparseable
    /// Keychain entry exists but carries only MCP-OAuth state.
    case oauthConfiguration

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Claude request failed: \(detail)"
        case .invalidResponse:
            return "Claude returned an invalid response."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Claude rejected the credentials (HTTP \(code)). Re-auth or switch the usage source."
            }
            return "Claude request failed with HTTP \(code)."
        case .unparseable:
            return "Claude returned an unreadable response."
        case .oauthConfiguration:
            return "Claude OAuth is not configured (Keychain entry lacks claudeAiOauth). Re-auth with the Claude CLI or switch the usage source."
        }
    }
}

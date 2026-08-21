import Foundation

// MARK: - Codex provider

/// Codex (OpenAI) usage provider.
///
/// Primary source: OAuth tokens from `~/.codex/auth.json`
/// (`$CODEX_HOME` override) queried against the wham usage endpoint.
/// The auth file is opened strictly read-only — never written, never
/// refreshed by this provider. Multiple Codex homes (e.g. work/personal)
/// are supported as a list; each is reported as its own provider entry.
public struct CodexUsageProvider: AIUsageProvider, Sendable {
    public let id: String
    public let displayName: String

    /// Home directory containing `auth.json` (default `~/.codex` /
    /// `$CODEX_HOME`).
    public let homeDirectory: String

    public var isConfigured: Bool { !accessToken.isEmpty }

    public var strategies: [any AIUsageStrategy] {
        [CodexOAuthStrategy(
            accessToken: accessToken,
            accountLabel: homeDirectory,
            network: network
        )]
    }

    private let accessToken: String
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - homeDirectory: Codex home (default `$CODEX_HOME` or
    ///     `~/.codex`); the OAuth token is read from `<home>/auth.json`.
    ///   - accessToken: explicit token override (test seam).
    ///   - network: injectable network seam for tests.
    public init(
        homeDirectory: String? = nil,
        accessToken: String? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let resolvedHome = homeDirectory
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        self.homeDirectory = resolvedHome
        self.id = "codex"
        self.displayName = "Codex"
        self.accessToken = accessToken ?? CodexAuthStore().readAccessToken(home: resolvedHome) ?? ""
        self.network = network
    }

    /// All default Codex homes, one provider entry each.
    public static func all() -> [CodexUsageProvider] {
        [CodexUsageProvider()]
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "Codex CLI OAuth token (~/.codex/auth.json)"
        )
    }

    /// Reads the Codex OAuth auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let resolvedHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        let store = CodexAuthStore()
        let token = store.readAccessToken(home: resolvedHome)
        if let token, !token.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via Codex CLI OAuth",
                source: "file"
            )
        }
        let authURL = URL(fileURLWithPath: resolvedHome).appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authURL.path) {
            return ExternalAuthState(
                status: .expired,
                detail: "Codex auth file found but no valid token — re-auth with the Codex CLI",
                source: "file"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Codex credentials found — sign in with the Codex CLI",
            source: nil
        )
    }
}

// MARK: - Auth store (read-only)

/// Read access to a Codex home's `auth.json`. Opens with
/// `Data(contentsOf:)` only — the file is never written or refreshed.
public struct CodexAuthStore: Sendable {
    public init() {}

    /// The OAuth access token from `<home>/auth.json` (prefers
    /// `OPENAI_API_KEY`-shaped `access_token`), or `nil` when absent.
    public func readAccessToken(home: String) -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let token = root["access_token"] as? String, !token.isEmpty {
            return token
        }
        if let tokens = root["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    /// Identity (email + plan) from the JWT claims embedded in `auth.json`
    /// (e.g. `openai_login` → `sub`/`email`). Returns `nil` when absent.
    public func identity(home: String) -> CodexIdentity? {
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let claims: [String: Any]?
        if let login = root["openai_login"] as? [String: Any] {
            claims = login
        } else if let session = root["session"] as? [String: Any] {
            claims = session
        } else {
            claims = nil
        }
        guard let claims else { return nil }
        return CodexIdentity(
            email: claims["email"] as? String,
            plan: claims["plan"] as? String ?? claims["plan_type"] as? String
        )
    }
}

/// Identity extracted from Codex auth claims (email + plan).
public struct CodexIdentity: Sendable, Equatable {
    public let email: String?
    public let plan: String?
}

// MARK: - Strategy

/// Fetches Codex usage from the wham endpoint.
///
/// `GET https://chatgpt.com/backend-api/wham/usage` with
/// `Authorization: Bearer <token>`.
public struct CodexOAuthStrategy: AIUsageStrategy, Sendable {
    public let source = "oauth"

    private let accessToken: String
    private let accountLabel: String
    private let network: any NetworkServiceProtocol

    public init(
        accessToken: String,
        accountLabel: String,
        network: any NetworkServiceProtocol
    ) {
        self.accessToken = accessToken
        self.accountLabel = accountLabel
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: CodexWhamUsage = try await AIUsageHTTP.json(
            request,
            as: CodexWhamUsage.self,
            providerID: "codex",
            network: network
        )

        var meters: [AIUsageMeter] = []
        // Session (primary) and weekly (secondary) windows as separate meters.
        for window in [payload.rateLimit?.primaryWindow, payload.rateLimit?.secondaryWindow]
            .compactMap({ $0 }) {
            guard let limit = window.limit, limit > 0 else { continue }
            meters.append(AIUsageMeter(
                label: window.window,
                used: Decimal(window.utilized ?? 0),
                limit: Decimal(limit),
                unit: .percent,
                resetsAt: window.resetDate
            ))
        }
        // Model-specific additional rate limits (e.g. Codex Spark).
        for extra in payload.additionalRateLimits ?? [] {
            guard let limit = extra.limit, limit > 0 else { continue }
            meters.append(AIUsageMeter(
                label: extra.title ?? extra.window,
                used: extra.utilized.map { Decimal($0) },
                limit: Decimal(limit),
                unit: .percent,
                resetsAt: extra.resetDate
            ))
        }

        return AIUsageSnapshot(
            providerID: "codex",
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response models

struct CodexWhamUsage: Decodable {
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalRateLimit]?
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
}

struct CodexWindow: Decodable {
    let window: String
    let utilized: Double?
    let limit: Double?
    let resetDate: Date?

    enum CodingKeys: String, CodingKey {
        case window
        case utilized
        case limit
        // convertFromSnakeCase normalizes reset_date → resetDate, so the
        // stored key must round-trip through that exact pair.
        case resetDate
    }
}

struct CodexAdditionalRateLimit: Decodable {
    let window: String
    let title: String?
    let utilized: Double?
    let limit: Double?
    let resetDate: Date?

    enum CodingKeys: String, CodingKey {
        case window
        case title
        case utilized
        case limit
        case resetDate
    }
}

// MARK: - Codex: shared HTTP layer

// Codex uses AIUsageHTTP.json (Sources/SymTuneCore/AIUsageHTTP.swift) for
// request execution, status mapping and snake_case decoding; there is no
// provider-private error enum. 401/403 → .notConfigured, 429 → .rateLimited.

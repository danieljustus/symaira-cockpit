import Foundation

// MARK: - OpenRouter provider

/// OpenRouter usage provider — the first vertical AI-usage provider.
///
/// Data source: the credits/key API at `https://openrouter.ai/api/v1`.
/// Authentication is a plain API key (`sk-or-v1-…`) read from the Keychain
/// (fallback: `OPENROUTER_API_KEY` environment variable). The key is never
/// stored in `config.toml` and never included in any error message.
public struct OpenRouterUsageProvider: AIUsageProvider, Sendable {
    public let id = "openrouter"
    public let displayName = "OpenRouter"

    /// Whether a usable API key is present. Unconfigured providers must
    /// report "not set up" instead of erroring.
    ///
    /// The key is resolved here (not at construction), so a key saved or
    /// cleared while the process runs takes effect without a relaunch (issue
    /// #324) in both directions.
    public var isConfigured: Bool { !resolveKey().isEmpty }

    public var strategies: [any AIUsageStrategy] {
        let key = resolveKey()
        guard !key.isEmpty else { return [] }
        return [OpenRouterAPIStrategy(apiKey: key, baseURL: baseURL, network: network)]
    }

    /// Lazily resolves the current API key on every access. When an explicit
    /// `apiKey` was passed it is a frozen test seam; otherwise the default
    /// reads `OPENROUTER_API_KEY` (env) then the Keychain on each call, so a
    /// credential change is honoured without rebuilding the provider.
    private let keyResolver: @Sendable () -> String
    private let baseURL: URL
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - apiKey: explicit key (test seam; frozen); when `nil`, the key is
    ///     resolved lazily from `OPENROUTER_API_KEY` then the Keychain on
    ///     every access.
    ///   - baseURL: API base; defaults to the `OPENROUTER_API_URL`
    ///     environment override or `https://openrouter.ai/api/v1`.
    ///   - network: injectable network seam for tests.
    public init(
        apiKey: String? = nil,
        baseURL: URL? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let resolver: @Sendable () -> String
        if let apiKey {
            // Explicit key: a frozen value (the original construction-time
            // semantics), used as the test seam.
            resolver = { apiKey }
        } else {
            resolver = {
                if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] {
                    return envKey
                }
                return KeychainCredentials.read(
                    service: "com.symaira.symtune",
                    account: "openrouter-api-key"
                ) ?? ""
            }
        }
        self.init(keyResolver: resolver, baseURL: baseURL, network: network)
    }

    /// Internal test seam (issue #324): inject a resolver whose value can
    /// change between accesses, letting a test flip `isConfigured` / the
    /// strategies without rebuilding the provider.
    init(
        keyResolver: @escaping @Sendable () -> String,
        baseURL: URL? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        self.keyResolver = keyResolver
        let envURL = ProcessInfo.processInfo.environment["OPENROUTER_API_URL"]
            .flatMap(URL.init(string:))
        self.baseURL = baseURL ?? envURL ?? URL(string: "https://openrouter.ai/api/v1")!
        self.network = network
    }

    private func resolveKey() -> String { keyResolver() }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .apiKey(account: "openrouter-api-key"),
            sourceLabel: "API key (env OPENROUTER_API_KEY or Keychain)"
        )
    }
}

// MARK: - Strategy

/// Fetches OpenRouter credit/usage state via the key endpoint.
///
/// `GET {base}/auth/key` with `Authorization: Bearer <apiKey>` returns the
/// key's label, total usage, limit, rate limits and free-tier flag.
public struct OpenRouterAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let apiKey: String
    private let baseURL: URL
    private let network: any NetworkServiceProtocol

    public init(apiKey: String, baseURL: URL, network: any NetworkServiceProtocol) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = baseURL.appendingPathComponent("auth/key")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("symtune", forHTTPHeaderField: "X-Title")

        let payload: OpenRouterKeyResponse
        do {
            payload = try await AIUsageHTTP.json(
                request,
                as: OpenRouterKeyResponse.self,
                providerID: "openrouter",
                network: network
            )
        }
        // The shared layer maps 401/403 → .notConfigured and 429 →
        // .rateLimited, and never embeds the response body in an error (a
        // gateway page can echo the request headers back, including the key).

        let key = payload.data
        var meters: [AIUsageMeter] = []

        // Primary meter: spend against the key limit (USD).
        if let limit = key.limit {
            meters.append(AIUsageMeter(
                label: "Key limit",
                used: key.usage.map { Decimal($0) },
                limit: Decimal(limit),
                unit: .currency("USD"),
                resetsAt: key.usagePeriod?.endTime
            ))
        } else if let usage = key.usage {
            meters.append(AIUsageMeter(
                label: "Spend",
                used: Decimal(usage),
                limit: nil,
                unit: .currency("USD"),
                resetsAt: key.usagePeriod?.endTime
            ))
        }

        // Secondary meter: free-tier daily request rate limit.
        // OpenRouter reports `-1` (or other non-negative-free sentinels) when
        // no real request cap is configured; that carries no information, so
        // omit the meter entirely rather than rendering a bogus negative limit.
        if let rateLimit = key.rateLimit, let requests = rateLimit.requests, requests >= 0 {
            meters.append(AIUsageMeter(
                label: "Requests",
                used: nil,
                limit: Decimal(requests),
                unit: .requests,
                resetsAt: nil
            ))
        }

        return AIUsageSnapshot(
            providerID: "openrouter",
            meters: meters,
            balance: key.creditBalance.map { Decimal($0) },
            currency: "USD",
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response model

struct OpenRouterKeyResponse: Decodable {
    let data: OpenRouterKeyData
}

struct OpenRouterKeyData: Decodable {
    let label: String?
    let usage: Double?
    let limit: Double?
    let isFreeTier: Bool?
    let rateLimit: OpenRouterRateLimit?
    let usagePeriod: OpenRouterUsagePeriod?
    /// Total credits purchased; balance = credits - usage.
    let totalCredits: Double?

    var creditBalance: Double? {
        guard let totalCredits, let usage else { return nil }
        return totalCredits - usage
    }
}

struct OpenRouterRateLimit: Decodable {
    let requests: Int?
    let interval: String?
}

struct OpenRouterUsagePeriod: Decodable {
    let startTime: Date?
    let endTime: Date?
}

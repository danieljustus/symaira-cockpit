import Foundation

// MARK: - Moonshot provider

/// Moonshot (Kimi Open Platform) usage provider.
///
/// Pay-as-you-go balance reported by `GET /v1/users/me/balance`; no session
/// or weekly quota windows. Region-dependent host: `api.moonshot.ai`
/// (international, USD) or `api.moonshot.cn` (China mainland, CNY).
/// The API key lives in the Keychain (`MOONSHOT_API_KEY` / `MOONSHOT_KEY`
/// fallback); currency amounts are never added across currency boundaries.
public struct MoonshotUsageProvider: AIUsageProvider, Sendable {
    public let id = "moonshot"
    public let displayName = "Moonshot"

    /// API region — changes the host and currency.
    public enum Region: String, Sendable, CaseIterable {
        case international = "ai"
        case china = "cn"

        var host: String {
            switch self {
            case .international: return "api.moonshot.ai"
            case .china: return "api.moonshot.cn"
            }
        }

        var currency: String {
            switch self {
            case .international: return "USD"
            case .china: return "CNY"
            }
        }
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    public var strategies: [any AIUsageStrategy] {
        [MoonshotAPIStrategy(apiKey: apiKey, region: region, network: network)]
    }

    private let apiKey: String
    private let region: Region
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - apiKey: explicit key; defaults to Keychain lookup with
    ///     `MOONSHOT_API_KEY` / `MOONSHOT_KEY` fallback.
    ///   - region: `.ai` (default) or `.cn`; `MOONSHOT_REGION=china` env
    ///     override applied when no explicit region is passed.
    ///   - network: injectable network seam for tests.
    public init(
        apiKey: String? = nil,
        region: Region? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let envKey = ProcessInfo.processInfo.environment["MOONSHOT_API_KEY"]
            ?? ProcessInfo.processInfo.environment["MOONSHOT_KEY"]
        self.apiKey = apiKey ?? envKey ?? KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: "moonshot-api-key"
        ) ?? ""
        let envRegion = ProcessInfo.processInfo.environment["MOONSHOT_REGION"]
            .flatMap(Region.init(rawValue:))
        self.region = region ?? envRegion ?? .international
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .apiKey(account: "moonshot-api-key"),
            sourceLabel: "API key (env MOONSHOT_API_KEY or Keychain)"
        )
    }
}

// MARK: - Strategy

/// Fetches the Moonshot pay-as-you-go balance.
///
/// `GET {host}/v1/users/me/balance` with `Authorization: Bearer <apiKey>`.
public struct MoonshotAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let apiKey: String
    private let region: MoonshotUsageProvider.Region
    private let network: any NetworkServiceProtocol

    public init(
        apiKey: String,
        region: MoonshotUsageProvider.Region,
        network: any NetworkServiceProtocol
    ) {
        self.apiKey = apiKey
        self.region = region
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = URL(string: "https://\(region.host)/v1/users/me/balance")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: MoonshotBalanceResponse = try await AIUsageHTTP.json(
            request,
            as: MoonshotBalanceResponse.self,
            providerID: "moonshot",
            network: network
        )

        var meters: [AIUsageMeter] = []
        if let cash = payload.cashBalanceValue {
            meters.append(AIUsageMeter(
                label: "Cash balance",
                used: Decimal(cash),
                limit: nil,
                unit: .currency(region.currency)
            ))
        }
        if let voucher = payload.voucherBalanceValue {
            meters.append(AIUsageMeter(
                label: "Voucher balance",
                used: Decimal(voucher),
                limit: nil,
                unit: .currency(region.currency)
            ))
        }

        return AIUsageSnapshot(
            providerID: "moonshot",
            meters: meters,
            balance: payload.availableBalanceValue.map { Decimal($0) },
            currency: region.currency,
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response model

/// Moonshot returns balances as decimal strings (`"42.50"`).
struct MoonshotBalanceResponse: Decodable {
    let availableBalance: String?
    let voucherBalance: String?
    let cashBalance: String?

    var availableBalanceValue: Double? { availableBalance.flatMap(Double.init) }
    var voucherBalanceValue: Double? { voucherBalance.flatMap(Double.init) }
    var cashBalanceValue: Double? { cashBalance.flatMap(Double.init) }
}

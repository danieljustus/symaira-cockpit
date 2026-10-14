import Foundation

// MARK: - AI usage snapshot model

/// Unit of an AI usage meter. Different providers meter tokens, requests,
/// credits, or spending in a currency; the normalized model keeps them apart.
public enum AIUsageUnit: Codable, Sendable, Equatable {
    case tokens
    case requests
    case credits
    case currency(String)
    case percent

    public var unitLabel: String {
        switch self {
        case .tokens: return "tokens"
        case .requests: return "requests"
        case .credits: return "credits"
        case .currency(let code): return code
        case .percent: return "%"
        }
    }
}

/// One normalized usage meter (for example, a session window or weekly quota).
public struct AIUsageMeter: Codable, Sendable, Equatable {
    public let label: String
    public let used: Decimal?
    public let limit: Decimal?
    public let unit: AIUsageUnit
    public let resetsAt: Date?

    public init(
        label: String,
        used: Decimal? = nil,
        limit: Decimal? = nil,
        unit: AIUsageUnit,
        resetsAt: Date? = nil
    ) {
        self.label = label
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetsAt = resetsAt
    }
}

/// Normalized view of one provider's AI usage.
public struct AIUsageSnapshot: Codable, Sendable, Equatable {
    public let providerID: String
    public let meters: [AIUsageMeter]
    public let balance: Decimal?
    public let currency: String?
    public let fetchedAt: Date
    /// The symbrain strategy that produced the data (`oauth`, `cli`, `web`,
    /// `api`, or `local`).
    public let source: String

    public var staleness: TimeInterval { Date().timeIntervalSince(fetchedAt) }

    private enum CodingKeys: String, CodingKey {
        case providerID = "providerId"
        case meters
        case balance
        case currency
        case fetchedAt
        case source
    }

    public init(
        providerID: String,
        meters: [AIUsageMeter],
        balance: Decimal? = nil,
        currency: String? = nil,
        fetchedAt: Date = Date(),
        source: String
    ) {
        self.providerID = providerID
        self.meters = meters
        self.balance = balance
        self.currency = currency
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

// MARK: - Provider metadata

/// Metadata used by the preferences UI. Usage fetching is intentionally not a
/// provider concern anymore: the one runtime client invokes `symbrain usage`.
public protocol AIUsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// The latest `configured` value reported by symbrain.
    var isConfigured: Bool { get }
    /// Auth state reported by symbrain, when the UI needs more detail.
    var authState: ExternalAuthState { get }
    var credentialDescriptor: AIUsageCredentialDescriptor? { get }
    var credentialSource: String { get }
}

public extension AIUsageProvider {
    var credentialDescriptor: AIUsageCredentialDescriptor? { nil }
    var credentialSource: String { authState.source ?? "none" }
}

/// Describes how a provider's credentials are supplied in Preferences.
public struct AIUsageCredentialDescriptor: Sendable {
    public enum AuthKind: Sendable {
        /// A value entered in the UI and stored in the macOS Keychain.
        case apiKey(account: String)
        /// Auth is owned by a native CLI/OAuth flow and is reported by symbrain.
        case externalToken(resolver: ExternalTokenResolver)
        /// Multiple auth sources; the UI renders the external status summary.
        case multi([AuthKind])
    }

    public struct ExternalTokenResolver: @unchecked Sendable {
        public let read: () -> ExternalAuthState
        public init(read: @escaping () -> ExternalAuthState) { self.read = read }
    }

    public let authKind: AuthKind
    public let sourceLabel: String

    public init(authKind: AuthKind, sourceLabel: String) {
        self.authKind = authKind
        self.sourceLabel = sourceLabel
    }
}

/// Auth state returned by symbrain's stable usage JSON contract.
public struct ExternalAuthState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case available
        case missing
        case expired
        case partial
    }

    public let status: Status
    public let detail: String
    public let source: String?

    public init(status: Status, detail: String, source: String?) {
        self.status = status
        self.detail = detail
        self.source = source
    }
}

/// Errors are intentionally generic at the service boundary: the CLI's
/// stderr and the UI must never receive subprocess output that might contain a
/// credential or a provider response body.
public enum AIUsageError: Error, Sendable, LocalizedError {
    case unknownProvider(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id): return "unknown AI usage provider '\(id)'"
        case .unavailable: return "AI usage unavailable"
        }
    }
}

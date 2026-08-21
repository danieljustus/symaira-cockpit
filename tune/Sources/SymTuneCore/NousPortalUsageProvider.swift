import Foundation

// MARK: - Nous Portal provider

/// Nous Portal usage provider — reads credits from the Portal account API.
///
/// The Hermes CLI persists its auth state in `~/.hermes/auth.json`
/// (override: `HERMES_HOME`). Nous uses single-use refresh tokens and
/// protects that store with cross-process file locking, so this provider
/// opens it **strictly read-only**: it never refreshes, rotates, or writes
/// anything back. An expired access token surfaces as "re-auth needed"
/// instead of being refreshed behind the CLI's back.
public struct NousPortalUsageProvider: AIUsageProvider, Sendable {
    public let id = "nous"
    public let displayName = "Nous Portal"

    public var isConfigured: Bool { !accessToken.isEmpty }

    public var strategies: [any AIUsageStrategy] {
        [NousPortalAPIStrategy(
            accessToken: accessToken,
            portalBaseURL: portalBaseURL,
            network: network
        )]
    }

    private let accessToken: String
    private let portalBaseURL: URL
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - accessToken: explicit token; defaults to the invoke JWT /
    ///     access token from the Hermes auth store.
    ///   - portalBaseURL: defaults to `HERMES_PORTAL_BASE_URL` override or
    ///     `https://portal.nousresearch.com`.
    ///   - authStore: injectable auth-store reader (test seam).
    ///   - network: injectable network seam for tests.
    public init(
        accessToken: String? = nil,
        portalBaseURL: URL? = nil,
        authStore: NousAuthStoreReading = NousAuthStore(),
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let envBase = ProcessInfo.processInfo.environment["HERMES_PORTAL_BASE_URL"]
            .flatMap(URL.init(string:))
        self.portalBaseURL = portalBaseURL
            ?? envBase
            ?? URL(string: "https://portal.nousresearch.com")!
        self.accessToken = accessToken ?? authStore.readAccessToken() ?? ""
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "Hermes CLI auth store (~/.hermes/auth.json)"
        )
    }

    /// Reads the Nous Portal auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let store = NousAuthStore()
        let token = store.readAccessToken()
        if let token, !token.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via Hermes CLI auth store",
                source: "file"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Nous Portal credentials found — sign in with the Hermes CLI",
            source: nil
        )
    }
}

// MARK: - Auth store (read-only)

/// Read access to the Hermes auth store. Only a tiny, read-only slice is
/// used; nothing is ever written or rotated.
public protocol NousAuthStoreReading: Sendable {
    /// The Nous Portal access token (prefers the invoke JWT), or `nil`
    /// when absent/expired.
    func readAccessToken() -> String?
}

/// Production reader for `~/.hermes/auth.json` (override: `HERMES_HOME`).
/// Opens the file with `Data(contentsOf:)` only — no locks, no writes, no
/// token rotation. Byte-identical store guaranteed by construction.
public struct NousAuthStore: NousAuthStoreReading, Sendable {
    public init() {}

    public func readAccessToken() -> String? {
        let url = Self.authStoreURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Shape: {"version": 1, "providers": [{"id": "nous", ...state...}]}
        guard let providers = root["providers"] as? [[String: Any]] else { return nil }
        for provider in providers {
            guard (provider["id"] as? String) == "nous" else { continue }
            // Prefer the scoped invoke JWT, then the access token.
            let token = (provider["invoke_jwt"] as? String)
                ?? (provider["access_token"] as? String)
            guard let token, !token.isEmpty else { return nil }
            // JWT-shaped tokens get an expiry check; plain tokens pass through.
            if token.contains("."), NousJWT.expiry(of: token) == nil {
                return nil // expired or unparseable → treat as re-auth needed
            }
            return token
        }
        return nil
    }

    /// `$HERMES_HOME/auth.json`, falling back to `~/.hermes/auth.json`.
    static func authStoreURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["HERMES_HOME"],
           !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes")
            .appendingPathComponent("auth.json")
    }
}

// MARK: - JWT helper

enum NousJWT {
    /// Expiry date of an unverified JWT (payload segment only), or `nil`
    /// when the token is expired or not JWT-shaped.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4.
        let padded = payload.padding(
            toLength: payload.count + (4 - payload.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        let date = Date(timeIntervalSince1970: exp)
        return date > Date() ? date : nil
    }
}

// MARK: - Strategy

/// Fetches Portal credits via the account API.
///
/// `GET {base}/api/oauth/account` with `Authorization: Bearer <token>`.
/// Read-only; an expired token surfaces as a re-auth hint, never a refresh.
public struct NousPortalAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let accessToken: String
    private let portalBaseURL: URL
    private let network: any NetworkServiceProtocol

    public init(
        accessToken: String,
        portalBaseURL: URL,
        network: any NetworkServiceProtocol
    ) {
        self.accessToken = accessToken
        self.portalBaseURL = portalBaseURL
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = portalBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("oauth")
            .appendingPathComponent("account")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: NousAccountResponse = try await AIUsageHTTP.json(
            request,
            as: NousAccountResponse.self,
            providerID: "nous",
            network: network
        )
        // A 401/403 from the shared layer maps to .notConfigured: the invoke
        // JWT is no longer valid (re-auth needed) and we never refresh it.

        var meters: [AIUsageMeter] = []
        if let access = payload.paidServiceAccess {
            if let remaining = access.subscriptionCreditsRemaining {
                meters.append(AIUsageMeter(
                    label: "Subscription credits",
                    used: Decimal(remaining),
                    limit: nil,
                    unit: .credits
                ))
            }
            if let purchased = access.purchasedCreditsRemaining {
                meters.append(AIUsageMeter(
                    label: "Purchased credits",
                    used: Decimal(purchased),
                    limit: nil,
                    unit: .credits
                ))
            }
        }
        if let subscription = payload.subscription {
            if let remaining = subscription.creditsRemaining {
                meters.append(AIUsageMeter(
                    label: "Plan credits remaining",
                    used: Decimal(remaining),
                    limit: subscription.monthlyCredits.map { Decimal($0) },
                    unit: .credits,
                    resetsAt: subscription.currentPeriodEnd
                ))
            }
            if let rollover = subscription.rolloverCredits {
                meters.append(AIUsageMeter(
                    label: "Rollover credits",
                    used: Decimal(rollover),
                    limit: nil,
                    unit: .credits
                ))
            }
        }

        return AIUsageSnapshot(
            providerID: "nous",
            meters: meters,
            balance: payload.paidServiceAccess?.totalUsableCredits.map { Decimal($0) },
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response model

struct NousAccountResponse: Decodable {
    let subscription: NousSubscription?
    let paidServiceAccess: NousPaidServiceAccess?
}

struct NousSubscription: Decodable {
    let plan: String?
    let tier: Int?
    let monthlyCharge: Double?
    let monthlyCredits: Double?
    let currentPeriodEnd: Date?
    let creditsRemaining: Double?
    let rolloverCredits: Double?
}

struct NousPaidServiceAccess: Decodable {
    let allowed: Bool?
    let paidAccess: Bool?
    let hasActiveSubscription: Bool?
    let subscriptionCreditsRemaining: Double?
    let purchasedCreditsRemaining: Double?
    let totalUsableCredits: Double?
}

import Foundation

// MARK: - Kimi provider

/// Kimi For Coding usage provider.
///
/// Tracks the Kimi Code subscription quota (weekly request pool plus the
/// 5-hour rate-limit window) via `GET https://api.kimi.com/coding/v1/usages`.
/// Distinct from the Moonshot/Kimi Open Platform balance — see
/// ``MoonshotUsageProvider`` for that.
///
/// Fallback chain (first success wins):
/// 1. `api` — API key from the Keychain or `KIMI_CODE_API_KEY` env.
/// 2. `cli` — fresh access token from the official Kimi Code CLI
///    (`~/.kimi-code/credentials/kimi-code.json`, legacy `~/.kimi` home
///    supported), read strictly read-only together with the stable
///    `device_id`. The refresh token is never used and the credential file
///    is never written.
/// 3. `web` — manually supplied `kimi-auth` cookie JWT via `KIMI_AUTH_TOKEN`
///    against the Kimi web billing endpoint. No browser import (that would
///    require Full Disk Access, which is out of scope).
public struct KimiUsageProvider: AIUsageProvider, Sendable {
    public let id = "kimi"
    public let displayName = "Kimi Code"

    public var isConfigured: Bool {
        apiKey != nil || cliAccessToken != nil || authToken != nil
    }

    public var strategies: [any AIUsageStrategy] {
        var strategies: [any AIUsageStrategy] = []
        if let apiKey {
            strategies.append(KimiAPIStrategy(
                apiKey: apiKey,
                baseURL: baseURL,
                network: network
            ))
        }
        if let cliAccessToken {
            strategies.append(KimiCLIStrategy(
                accessToken: cliAccessToken,
                identityHeaders: KimiCLIIdentityHeaders(
                    deviceID: cliDeviceID,
                    hostName: ProcessInfo.processInfo.hostName
                ).all,
                baseURL: baseURL,
                network: network
            ))
        }
        if let authToken {
            strategies.append(KimiWebStrategy(authToken: authToken, network: network))
        }
        return strategies
    }

    private let apiKey: String?
    private let cliAccessToken: String?
    private let cliDeviceID: String?
    private let authToken: String?
    private let baseURL: URL
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - apiKey: explicit API key; defaults to the Keychain
    ///     (`kimi-api-key` account) with `KIMI_CODE_API_KEY` env fallback.
    ///   - cliHome: Kimi Code CLI home (default `$KIMI_CODE_HOME`,
    ///     `~/.kimi-code`, or legacy `~/.kimi`); the access token and device
    ///     id are read from here read-only.
    ///   - authToken: manual `kimi-auth` web cookie JWT; `KIMI_AUTH_TOKEN`
    ///     env fallback.
    ///   - baseURL: endpoint override (tests only; `KIMI_CODE_BASE_URL` env).
    ///   - network: injectable network seam for tests.
    public init(
        apiKey: String? = nil,
        cliHome: String? = nil,
        authToken: String? = nil,
        baseURL: URL? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let envAPIKey = ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"]
        self.apiKey = apiKey ?? envAPIKey ?? KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: "kimi-api-key"
        )

        let resolvedHome = cliHome
            ?? ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            ?? KimiUsageProvider.defaultCLIHome()
        let cliStore = KimiCLICredentialStore(home: resolvedHome)
        self.cliAccessToken = cliStore.readAccessToken()
        self.cliDeviceID = cliStore.readDeviceID()

        let envAuthToken = ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"]
        self.authToken = authToken ?? envAuthToken ?? KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: "kimi-auth-token"
        )

        if let baseURL {
            self.baseURL = baseURL
        } else if let envBase = ProcessInfo.processInfo.environment["KIMI_CODE_BASE_URL"],
                  let parsed = URL(string: envBase) {
            self.baseURL = parsed
        } else {
            self.baseURL = KimiUsageProvider.defaultAPIBaseURL
        }
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .multi([
                .apiKey(account: "kimi-api-key"),
                .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            ]),
            sourceLabel: "API key (KIMI_CODE_API_KEY) or Kimi Code CLI token"
        )
    }

    /// Reads the Kimi Code CLI auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let cliStore = KimiCLICredentialStore(home: defaultCLIHome())
        if let token = cliStore.readAccessToken(), !token.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Kimi Code CLI is signed in",
                source: "cli"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Kimi Code CLI credentials found",
            source: nil
        )
    }

    static let defaultAPIBaseURL = URL(string: "https://api.kimi.com")!

    /// Default Kimi Code CLI home: `~/.kimi-code` (current CLI layout), with
    /// a legacy `~/.kimi` fallback for installations that predate the
    /// migration marker.
    static func defaultCLIHome() -> String {
        let home = NSHomeDirectory()
        let current = home + "/.kimi-code"
        if FileManager.default.fileExists(atPath: current + "/credentials/kimi-code.json") {
            return current
        }
        let legacy = home + "/.kimi"
        if FileManager.default.fileExists(atPath: legacy + "/credentials/kimi-code.json") {
            return legacy
        }
        return current
    }
}

// MARK: - CLI credential store (read-only)

/// Read access to the Kimi Code CLI credential file and device id. Opens
/// files with `Data(contentsOf:)` only — never writes, never creates
/// missing files, never touches the refresh token.
public struct KimiCLICredentialStore: Sendable {
    public let home: String

    public init(home: String) {
        self.home = home
    }

    /// The fresh access token from `<home>/credentials/kimi-code.json`.
    public func readAccessToken() -> String? {
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent("credentials")
            .appendingPathComponent("kimi-code.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let token = root["access_token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// The stable device id from `<home>/device_id`, or `nil` when absent.
    /// The file is only read — never created (unlike the official client).
    public func readDeviceID() -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent("device_id")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let id = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty ?? true) ? nil : id
    }
}

// MARK: - Identity headers (CLI path)

/// The `X-Msh-*` headers the official Kimi Code CLI sends alongside its
/// token, derived from the stable device id and host metadata.
struct KimiCLIIdentityHeaders: Sendable {
    let deviceID: String?
    let hostName: String

    var all: [String: String] {
        var headers: [String: String] = [
            "X-Msh-Platform": "macos",
            "X-Msh-Device-Name": hostName,
        ]
        if let deviceID {
            headers["X-Msh-Device-Id"] = deviceID
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        headers["X-Msh-Os-Version"] = versionString
        headers["X-Msh-Device-Model"] = "macOS \(versionString)"
        return headers
    }
}

// MARK: - Strategies

/// Fetches Kimi Code usage with an API key.
///
/// `GET {base}/coding/v1/usages` with `Authorization: Bearer <apiKey>`.
public struct KimiAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let apiKey: String
    private let baseURL: URL
    private let network: any NetworkServiceProtocol

    public init(
        apiKey: String,
        baseURL: URL,
        network: any NetworkServiceProtocol
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let data = try await Self.performGET(
            baseURL: baseURL,
            token: apiKey,
            identityHeaders: [:],
            network: network
        )
        return try KimiUsageParsing.snapshot(
            providerID: "kimi",
            data: data,
            source: source,
            meterKeyPath: \.usage
        )
    }

    /// Shared GET against the Kimi Code usage endpoint.
    static func performGET(
        baseURL: URL,
        token: String,
        identityHeaders: [String: String],
        network: any NetworkServiceProtocol
    ) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent("coding/v1/usages")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        for (name, value) in identityHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw KimiError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KimiError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("kimi", retryAfter: retryAfterSeconds(from: http))
            }
            throw KimiError.httpStatus(http.statusCode)
        }
        return data
    }
}

/// Fetches Kimi Code usage with the CLI's fresh access token and the same
/// device identity headers the official CLI sends. Strictly read-only.
public struct KimiCLIStrategy: AIUsageStrategy, Sendable {
    public let source = "cli"

    private let accessToken: String
    private let identityHeaders: [String: String]
    private let baseURL: URL
    private let network: any NetworkServiceProtocol

    public init(
        accessToken: String,
        identityHeaders: [String: String],
        baseURL: URL,
        network: any NetworkServiceProtocol
    ) {
        self.accessToken = accessToken
        self.identityHeaders = identityHeaders
        self.baseURL = baseURL
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let data = try await KimiAPIStrategy.performGET(
            baseURL: baseURL,
            token: accessToken,
            identityHeaders: identityHeaders,
            network: network
        )
        return try KimiUsageParsing.snapshot(
            providerID: "kimi",
            data: data,
            source: source,
            meterKeyPath: \.usage
        )
    }
}

/// Fetches Kimi Code usage from the web billing endpoint with a manually
/// supplied `kimi-auth` cookie JWT.
///
/// `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
public struct KimiWebStrategy: AIUsageStrategy, Sendable {
    public let source = "web"

    private let authToken: String
    private let network: any NetworkServiceProtocol

    public init(authToken: String, network: any NetworkServiceProtocol) {
        self.authToken = authToken
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let endpoint = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw KimiError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KimiError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("kimi", retryAfter: retryAfterSeconds(from: http))
            }
            throw KimiError.httpStatus(http.statusCode)
        }
        return try KimiUsageParsing.webSnapshot(providerID: "kimi", data: data, source: source)
    }
}

// MARK: - Parsing

/// Shared parsing for the Kimi Code API and web billing responses.
enum KimiUsageParsing {
    /// Parses `GET /coding/v1/usages` (root `usage` + `limits`).
    static func snapshot(
        providerID: String,
        data: Data,
        source: String,
        meterKeyPath: KeyPath<KimiUsageResponse, KimiUsageDetail?>
    ) throws -> AIUsageSnapshot {
        let payload: KimiUsageResponse
        do {
            payload = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        } catch {
            throw KimiError.unparseable
        }
        let detail = payload[keyPath: meterKeyPath]
        var meters: [AIUsageMeter] = KimiUsageParsing.meters(from: detail, label: "Weekly quota")
        for limit in payload.limits ?? [] {
            meters.append(contentsOf: KimiUsageParsing.meters(
                from: limit.detail,
                label: KimiUsageParsing.windowLabel(limit.window)
            ))
        }
        return AIUsageSnapshot(
            providerID: providerID,
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }

    /// Parses the web `GetUsages` response (scoped `usages[]` entries).
    static func webSnapshot(providerID: String, data: Data, source: String) throws -> AIUsageSnapshot {
        let payload: KimiWebUsagesResponse
        do {
            payload = try JSONDecoder().decode(KimiWebUsagesResponse.self, from: data)
        } catch {
            throw KimiError.unparseable
        }
        var meters: [AIUsageMeter] = []
        let usages = payload.usages ?? []
        let coding = usages.first { $0.scope == "FEATURE_CODING" } ?? usages.first
        if let coding {
            meters.append(contentsOf: KimiUsageParsing.meters(from: coding.detail, label: "Weekly quota"))
            for limit in coding.limits ?? [] {
                meters.append(contentsOf: KimiUsageParsing.meters(
                    from: limit.detail,
                    label: KimiUsageParsing.windowLabel(limit.window)
                ))
            }
        }
        return AIUsageSnapshot(
            providerID: providerID,
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }

    /// One meter per usage detail (used/limit/reset), or none when the
    /// payload carries no usable numbers.
    static func meters(from detail: KimiUsageDetail?, label: String) -> [AIUsageMeter] {
        guard let detail,
              let used = detail.usedValue,
              let limit = detail.limitValue, limit > 0
        else { return [] }
        return [AIUsageMeter(
            label: label,
            used: Decimal(used),
            limit: Decimal(limit),
            unit: .requests,
            resetsAt: detail.resetDate
        )]
    }

    /// Human label for a rate-limit window, e.g. `5h window` for the
    /// 300-minute window; falls back to the raw window duration.
    static func windowLabel(_ window: KimiWindow?) -> String {
        guard let window, let duration = window.duration, duration > 0 else {
            return "Rate limit window"
        }
        if duration % 60 == 0 {
            return "\(duration / 60)h window"
        }
        return "\(duration)min window"
    }
}

// MARK: - Response models

/// Kimi Code API response (`GET /coding/v1/usages`).
struct KimiUsageResponse: Decodable {
    let usage: KimiUsageDetail?
    let limits: [KimiLimit]?
}

/// Web billing response (`GetUsages`).
struct KimiWebUsagesResponse: Decodable {
    let usages: [KimiWebUsage]?
}

struct KimiWebUsage: Decodable {
    let scope: String?
    let detail: KimiUsageDetail?
    let limits: [KimiLimit]?
}

struct KimiLimit: Decodable {
    let window: KimiWindow?
    let detail: KimiUsageDetail?
}

struct KimiWindow: Decodable {
    let duration: Int?
    let timeUnit: String?
}

/// Kimi returns quota numbers as decimal strings (`"2048"`) and reset times
/// with nanosecond fractional seconds (`2026-01-09T15:23:13.716839300Z`).
struct KimiUsageDetail: Decodable {
    let limit: String?
    let used: String?
    let remaining: String?
    let resetTime: String?

    var limitValue: Double? { limit.flatMap(Double.init) }
    var usedValue: Double? { used.flatMap(Double.init) }
    var remainingValue: Double? { remaining.flatMap(Double.init) }

    var resetDate: Date? {
        guard let resetTime else { return nil }
        return KimiUsageParsing.parseResetTime(resetTime)
    }
}

extension KimiUsageParsing {
    /// Parses Kimi reset timestamps: ISO8601 with optional nanosecond
    /// fractional seconds, falling back to plain ISO8601.
    static func parseResetTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
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

enum KimiError: Error, LocalizedError {
    case network(String)
    case invalidResponse
    case httpStatus(Int)
    case unparseable

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Kimi request failed: \(detail)"
        case .invalidResponse:
            return "Kimi returned an invalid response."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Kimi rejected the credential (HTTP \(code)). Check the API key or sign in with the Kimi Code CLI again."
            }
            return "Kimi request failed with HTTP \(code)."
        case .unparseable:
            return "Kimi returned an unreadable response."
        }
    }
}

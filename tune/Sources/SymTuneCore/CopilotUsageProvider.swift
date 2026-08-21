import Foundation

// MARK: - Copilot provider

/// GitHub Copilot usage provider.
///
/// Primary source: an existing Copilot OAuth token from the local Copilot
/// config (`~/.config/github-copilot/apps.json` / `hosts.json`) or the
/// Keychain, then the `copilot_internal/user` usage endpoint. A GitHub
/// Device-Flow is **never** started automatically in the background — it
/// exists as an explicit, user-initiated path only.
public struct CopilotUsageProvider: AIUsageProvider, Sendable {
    public let id = "copilot"
    public let displayName = "GitHub Copilot"

    /// Enterprise host override; `nil` = github.com.
    public let enterpriseHost: String?

    public var isConfigured: Bool { !accessToken.isEmpty }

    public var strategies: [any AIUsageStrategy] {
        [CopilotAPIStrategy(
            accessToken: accessToken,
            host: enterpriseHost ?? "github.com",
            network: network
        )]
    }

    private let accessToken: String
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - accessToken: explicit token; defaults to a read of the local
    ///     Copilot config files (`apps.json`, then `hosts.json`) and the
    ///     Keychain.
    ///   - enterpriseHost: GitHub Enterprise host (e.g.
    ///     `github.example.com`); `nil` = github.com.
    ///   - network: injectable network seam for tests.
    public init(
        accessToken: String? = nil,
        enterpriseHost: String? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        self.accessToken = accessToken
            ?? CopilotTokenStore().readToken()
            ?? ""
        self.enterpriseHost = enterpriseHost
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "GitHub Copilot OAuth token (~/.config/github-copilot)"
        )
    }

    /// Reads the Copilot OAuth auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let token = CopilotTokenStore().readToken()
        if let token, !token.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via GitHub Copilot",
                source: "keychain"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Copilot token found — sign in with the Copilot CLI",
            source: nil
        )
    }

    /// Device-flow entry point. This is the *only* place a device flow is
    /// started — callers (UI preferences) must invoke it from an explicit
    /// user action, never from a background refresh.
    public static func startDeviceFlow(
        host: String = "github.com",
        clientID: String = "Iv1.b507a08c87ecfe98"
    ) async throws -> URL {
        let base = host == "github.com" ? "https://github.com" : "https://\(host)"
        let codeURL = URL(string: "\(base)/login/device/code")!
        var request = URLRequest(url: codeURL)
        request.httpMethod = "POST"
        request.httpBody = "client_id=\(clientID)&scope=copilot".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8)
        else {
            throw CopilotError.deviceFlowFailed
        }
        // Response: device_code=…&user_code=XXXX-XXXX&verification_uri=…&interval=5
        let params = body.split(separator: "&").reduce(into: [String: String]()) { dict, part in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { dict[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let uri = params["verification_uri"],
              let userCode = params["user_code"]
        else {
            throw CopilotError.deviceFlowFailed
        }
        return Self.verificationURL(uri: uri, userCode: userCode)
    }

    /// Builds the verification URL for a device flow (testable seam).
    static func verificationURL(uri: String, userCode: String) -> URL {
        var components = URLComponents(string: uri)!
        components.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        return components.url!
    }
}

// MARK: - Token store (read-only)

/// Reads an existing Copilot OAuth token from local config — never starts
/// a device flow, never writes anything.
public struct CopilotTokenStore: Sendable {
    public init() {}

    /// Reads `oauth_token` from `~/.config/github-copilot/apps.json` (or
    /// `hosts.json`), preferring the first `github.com` entry.
    public func readToken() -> String? {
        let configDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("github-copilot")
        return readToken(fromDirectory: configDir.path)
    }

    /// Reads a token from an explicit config directory (test seam).
    func readToken(fromDirectory path: String) -> String? {
        for filename in ["apps.json", "hosts.json"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Prefer a github.com entry, fall back to any entry.
            if let token = token(from: root, hostPrefix: "github.com:") {
                return token
            }
            if let token = token(from: root, hostPrefix: nil) {
                return token
            }
        }
        return nil
    }

    private func token(from root: [String: Any], hostPrefix: String?) -> String? {
        for (key, value) in root {
            if let hostPrefix, !key.hasPrefix(hostPrefix) { continue }
            if let entry = value as? [String: Any],
               let token = entry["oauth_token"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }
}

// MARK: - Strategy

/// Fetches Copilot plan usage from the user endpoint.
///
/// `GET https://api.github.com/copilot_internal/user` (or the enterprise
/// host) with `Authorization: Bearer <token>`.
public struct CopilotAPIStrategy: AIUsageStrategy, Sendable {
    public let source = "api"

    private let accessToken: String
    private let host: String
    private let network: any NetworkServiceProtocol

    public init(accessToken: String, host: String, network: any NetworkServiceProtocol) {
        self.accessToken = accessToken
        self.host = host
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let base = host == "github.com"
            ? "https://api.github.com"
            : "https://\(host)/api/v3"
        let endpoint = URL(string: "\(base)/copilot_internal/user")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw CopilotError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CopilotError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("copilot", retryAfter: retryAfterSeconds(from: http))
            }
            throw CopilotError.httpStatus(http.statusCode)
        }

        let payload: CopilotUserResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(CopilotUserResponse.self, from: data)
        } catch {
            throw CopilotError.unparseable
        }

        var meters: [AIUsageMeter] = []
        // Premium-model requests quota as a meter with resetsAt.
        if let premium = payload.copilot?.chat?.premiumModelRequests {
            meters.append(AIUsageMeter(
                label: "Premium requests",
                used: premium.totalPremiumRequestsUsed.map { Decimal($0) },
                limit: premium.totalPremiumRequestsIncluded.map { Decimal($0) },
                unit: .requests,
                resetsAt: premium.usageResetDate
            ))
        }
        if let skills = payload.skillsChat?.totalPremiumRequestsUsed {
            meters.append(AIUsageMeter(
                label: "Skills chat requests",
                used: Decimal(skills),
                limit: nil,
                unit: .requests
            ))
        }

        return AIUsageSnapshot(
            providerID: "copilot",
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }
}

// MARK: - Response models

struct CopilotUserResponse: Decodable {
    let copilot: CopilotState?
    let skillsChat: CopilotSkillsChat?
}

struct CopilotState: Decodable {
    let chat: CopilotChat?
}

struct CopilotChat: Decodable {
    let premiumModelRequests: CopilotPremiumRequests?
}

struct CopilotPremiumRequests: Decodable {
    let totalPremiumRequestsUsed: Int?
    let totalPremiumRequestsIncluded: Int?
    let usageResetDate: Date?

    enum CodingKeys: String, CodingKey {
        // convertFromSnakeCase normalizes the JSON keys to these exact
        // camelCase forms, so the stored keys must round-trip through them.
        case totalPremiumRequestsUsed
        case totalPremiumRequestsIncluded
        case usageResetDate
    }
}

struct CopilotSkillsChat: Decodable {
    let totalPremiumRequestsUsed: Int?

    enum CodingKeys: String, CodingKey {
        case totalPremiumRequestsUsed
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

enum CopilotError: Error, LocalizedError {
    case network(String)
    case invalidResponse
    case httpStatus(Int)
    case unparseable
    case deviceFlowFailed

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Copilot request failed: \(detail)"
        case .invalidResponse:
            return "Copilot returned an invalid response."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Copilot rejected the token (HTTP \(code)). Re-authenticate with GitHub Copilot."
            }
            return "Copilot request failed with HTTP \(code)."
        case .unparseable:
            return "Copilot returned an unreadable response."
        case .deviceFlowFailed:
            return "Copilot device flow could not be started."
        }
    }
}

import Foundation
import SQLite3

// MARK: - Cursor provider

/// Cursor usage provider.
///
/// Cursor is web-backed: quota comes from `cursor.com` endpoints with the
/// browser session. Two sources, in order:
///
/// 1. **Web** — a manually supplied `Cookie:` header (`CURSOR_COOKIE` env or
///    Keychain). No automatic browser import: that would need Full Disk
///    Access, which is out of scope.
/// 2. **Cursor.app local auth** — the signed-in Cursor app's access token
///    from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
///    (opened strictly read-only, WAL-aware). The token's JWT `sub` claim
///    derives the `WorkosCursorSessionToken` cookie used against the same
///    endpoints.
///
/// When every source fails the provider reports *not available* — never
/// silent zero values.
public struct CursorUsageProvider: AIUsageProvider, Sendable {
    public let id = "cursor"
    public let displayName = "Cursor"

    public var isConfigured: Bool {
        cookieHeader != nil || appAuthStore.loadSession() != nil
    }

    public var strategies: [any AIUsageStrategy] {
        var strategies: [any AIUsageStrategy] = []
        if let cookieHeader {
            strategies.append(CursorWebStrategy(
                cookieHeader: cookieHeader,
                network: network
            ) as any AIUsageStrategy)
        }
        if let session = appAuthStore.loadSession() {
            strategies.append(CursorLocalAuthStrategy(
                session: session,
                network: network
            ) as any AIUsageStrategy)
        }
        return strategies
    }

    private let cookieHeader: String?
    private let appAuthStore: CursorAppAuthStore
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - cookieHeader: manual cursor.com `Cookie:` header value;
    ///     `CURSOR_COOKIE` env fallback, then Keychain.
    ///   - vscdbPath: Cursor.app global state DB (default
    ///     `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`).
    ///   - network: injectable network seam for tests.
    public init(
        cookieHeader: String? = nil,
        vscdbPath: String? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        self.cookieHeader = cookieHeader
            ?? ProcessInfo.processInfo.environment["CURSOR_COOKIE"]
            ?? KeychainCredentials.read(service: "com.symaira.symtune", account: "cursor-cookie")
        self.appAuthStore = CursorAppAuthStore(dbPath: vscdbPath)
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "Cursor cookie (CURSOR_COOKIE) or Cursor.app auth"
        )
    }

    /// Reads the Cursor auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let store = CursorAppAuthStore()
        if let session = store.loadSession(), !session.accessToken.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Signed in via Cursor.app",
                source: "local"
            )
        }
        let envCookie = ProcessInfo.processInfo.environment["CURSOR_COOKIE"]
        let keychainCookie = KeychainCredentials.read(
            service: "com.symaira.symtune",
            account: "cursor-cookie"
        )
        if let cookie = envCookie ?? keychainCookie, !cookie.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Cookie configured (CURSOR_COOKIE or Keychain)",
                source: "keychain"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No Cursor credentials found — set CURSOR_COOKIE or sign in to Cursor.app",
            source: nil
        )
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

enum CursorError: Error, LocalizedError {
    case invalidCredentials
    case network(String)
    case httpStatus(Int)
    case parseFailed(String)
    case sqliteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Cursor session is invalid or expired. Re-import the cursor.com cookie or sign in to Cursor.app."
        case .network(let detail):
            return "Cursor request failed: \(detail)"
        case .httpStatus(let code):
            return "Cursor request failed with HTTP \(code)."
        case .parseFailed(let detail):
            return "Cursor returned an unreadable response: \(detail)"
        case .sqliteFailed(let detail):
            return "SQLite error reading Cursor app auth: \(detail)"
        }
    }
}

// MARK: - Cursor.app local auth (read-only)

/// A usable Cursor.app session derived from the app's global state DB.
struct CursorAppAuthSession: Sendable, Equatable {
    let accessToken: String

    /// The token must be a JWT with a `sub` user id and an unexpired `exp`.
    var isUsable: Bool {
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? userID()) != nil,
              let expiresAt = try? expiresAt()
        else { return false }
        return expiresAt.timeIntervalSinceNow > 60
    }

    /// First-party web session cookie: `WorkosCursorSessionToken=<userID>::<token>`
    /// with the separator URL-encoded, as the web client sends it.
    func cookieHeader() throws -> String {
        try "WorkosCursorSessionToken=\(userID())%3A%3A\(accessToken)"
    }

    /// The `sub` claim is `auth0|<tenant>|<userID>`; the last segment is the
    /// stable Cursor user id.
    func userID() throws -> String {
        let json = try payload()
        guard let subject = json["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorError.parseFailed("Cursor.app access token is missing a user ID")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorError.parseFailed("Cursor.app access token has an invalid user ID")
        }
        return userID
    }

    func expiresAt() throws -> Date {
        let json = try payload()
        guard let expiration = json["exp"] as? NSNumber else {
            throw CursorError.parseFailed("Cursor.app access token is missing an expiration")
        }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }

    private func payload() throws -> [String: Any] {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw CursorError.parseFailed("Cursor.app access token is not a JWT")
        }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CursorError.parseFailed("Cursor.app access token has an invalid payload")
        }
        return json
    }
}

/// Read access to the Cursor.app global state DB. Opens with
/// `SQLITE_OPEN_READONLY` only — the file is never written, and the WAL
/// sidecar rule is the same as the other local providers.
public struct CursorAppAuthStore: Sendable {
    public let dbPath: String

    public init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? Self.defaultDBPath()
    }

    /// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
    static func defaultDBPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// The app's access token, or `nil` when the DB or key is absent.
    func loadSession() -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            return try readSession()
        } catch {
            return nil
        }
    }

    private func readSession() throws -> CursorAppAuthSession? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CursorError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard try sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw CursorError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, transient)
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_ROW else {
            if stepResult == SQLITE_DONE { return nil }
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw CursorError.sqliteFailed(message)
        }

        let value: String
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            value = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            value = String(bytes: Data(bytes: bytes, count: length), encoding: .utf8) ?? ""
        default:
            return nil
        }
        guard !value.isEmpty else { return nil }
        let session = CursorAppAuthSession(accessToken: value)
        return session.isUsable ? session : nil
    }
}

// MARK: - Strategies

/// Fetches Cursor quota with a cursor.com session cookie.
///
/// `GET https://cursor.com/api/usage-summary` — plan usage, on-demand
/// usage, and the billing-cycle reset.
public struct CursorWebStrategy: AIUsageStrategy, Sendable {
    public let source = "web"

    private let cookieHeader: String
    private let network: any NetworkServiceProtocol

    public init(cookieHeader: String, network: any NetworkServiceProtocol) {
        self.cookieHeader = cookieHeader
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        try await Self.fetchSummary(cookieHeader: cookieHeader, network: network)
    }

    static func fetchSummary(
        cookieHeader: String,
        network: any NetworkServiceProtocol
    ) async throws -> AIUsageSnapshot {
        let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw CursorError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CursorError.network("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CursorError.invalidCredentials
            }
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("cursor", retryAfter: retryAfterSeconds(from: http))
            }
            throw CursorError.httpStatus(http.statusCode)
        }

        let summary: CursorUsageSummary
        do {
            summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw CursorError.parseFailed("usage summary is not JSON")
        }
        return Self.snapshot(from: summary)
    }

    /// Normalizes the usage summary into meters:
    /// - Plan usage (included) as a percent (or cents when no percent given)
    /// - Auto and API shares as percents, when reported
    /// - On-demand / extra usage as USD
    /// - Reset = billing cycle end
    static func snapshot(from summary: CursorUsageSummary) -> AIUsageSnapshot {
        var meters: [AIUsageMeter] = []
        let reset = summary.billingCycleEnd.flatMap(CursorParsing.parseDate)

        if let plan = summary.individualUsage?.plan, plan.enabled != false {
            if let percent = plan.totalPercentUsed {
                meters.append(AIUsageMeter(
                    label: "Plan usage",
                    used: Decimal(min(100, max(0, percent * 100))),
                    limit: 100,
                    unit: .percent,
                    resetsAt: reset
                ))
            } else if let used = plan.used, let limit = plan.limit, limit > 0 {
                meters.append(AIUsageMeter(
                    label: "Plan usage",
                    used: Decimal(used),
                    limit: Decimal(limit),
                    unit: .currency("USD"),
                    resetsAt: reset
                ))
            }
            if let auto = plan.autoPercentUsed {
                meters.append(AIUsageMeter(
                    label: "Auto usage",
                    used: Decimal(min(100, max(0, auto * 100))),
                    limit: 100,
                    unit: .percent,
                    resetsAt: reset
                ))
            }
            if let api = plan.apiPercentUsed {
                meters.append(AIUsageMeter(
                    label: "API usage",
                    used: Decimal(min(100, max(0, api * 100))),
                    limit: 100,
                    unit: .percent,
                    resetsAt: reset
                ))
            }
        }

        if let onDemand = summary.individualUsage?.onDemand, onDemand.enabled != false {
            if let used = onDemand.used, let limit = onDemand.limit, limit > 0 {
                meters.append(AIUsageMeter(
                    label: "On-demand usage",
                    used: Decimal(used),
                    limit: Decimal(limit),
                    unit: .currency("USD"),
                    resetsAt: reset
                ))
            } else if let used = onDemand.used {
                meters.append(AIUsageMeter(
                    label: "On-demand usage",
                    used: Decimal(used),
                    limit: nil,
                    unit: .currency("USD"),
                    resetsAt: reset
                ))
            }
        }

        return AIUsageSnapshot(
            providerID: "cursor",
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: "web"
        )
    }
}

/// Fetches Cursor quota using the Cursor.app access token (derived web
/// session). Reports the winning source as `local`.
public struct CursorLocalAuthStrategy: AIUsageStrategy, Sendable {
    public let source = "local"

    private let session: CursorAppAuthSession
    private let network: any NetworkServiceProtocol

    init(session: CursorAppAuthSession, network: any NetworkServiceProtocol) {
        self.session = session
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let cookie = try session.cookieHeader()
        let snapshot = try await CursorWebStrategy.fetchSummary(cookieHeader: cookie, network: network)
        return snapshot.taggingSource("local")
    }
}

// MARK: - Response models

/// `GET /api/usage-summary`. Money values are in cents.
struct CursorUsageSummary: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
    let overall: CursorOnDemandUsage?
}

struct CursorTeamUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

struct CursorPlanUsage: Decodable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let breakdown: CursorPlanBreakdown?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

struct CursorPlanBreakdown: Decodable {
    let included: Int?
    let bonus: Int?
    let total: Int?
}

struct CursorOnDemandUsage: Decodable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

// MARK: - Date parsing

enum CursorParsing {
    /// Cursor cycle dates: ISO8601 with optional fractional seconds.
    static func parseDate(_ value: String) -> Date? {
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

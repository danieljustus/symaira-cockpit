import Foundation
import SQLite3

// MARK: - OpenCode Go provider

/// OpenCode Go usage provider.
///
/// Tracks OpenCode Go subscription quota (rolling 5h window, weekly, monthly)
/// from two sources:
///
/// 1. **Local SQLite history** (`~/.local/share/opencode/opencode.db`) —
///    device-wide assistant cost rows for the `opencode-go` provider. Read
///    strictly read-only (WAL-aware). Because the numbers are device-wide,
///    the meter labels say so.
/// 2. **Web dashboard** (`POST https://opencode.ai/_server`) — server-side
///    quota percentages for a workspace, reached via opencode.ai cookies.
///
/// Strategy order depends on scope: with a workspace override or a cookie
/// the web path has precedence (local history would count other accounts);
/// unscoped, the local history is the primary path.
public struct OpenCodeUsageProvider: AIUsageProvider, Sendable {
    public let id = "opencode"
    public let displayName = "OpenCode Go"

    public var isConfigured: Bool {
        cookieHeader != nil || workspaceOverride != nil || localStore.isDetected
    }

    public var strategies: [any AIUsageStrategy] {
        let web = cookieHeader.map { cookie in
            OpenCodeWebStrategy(
                cookieHeader: cookie,
                workspaceOverride: workspaceOverride,
                network: network
            ) as any AIUsageStrategy
        }
        // The local strategy is only worth trying when the database exists.
        let local = localStore.isDetected
            ? OpenCodeGoLocalStrategy(databaseURL: localStore.databaseURL) as any AIUsageStrategy
            : nil

        var strategies: [any AIUsageStrategy] = []
        // Scoped (account/workspace chosen): web first, local fallback.
        if cookieHeader != nil || workspaceOverride != nil {
            if let web { strategies.append(web) }
            if let local { strategies.append(local) }
            return strategies
        }
        // Unscoped: local history is the primary path.
        if let local { strategies.append(local) }
        if let web { strategies.append(web) }
        return strategies
    }

    private let cookieHeader: String?
    private let workspaceOverride: String?
    private let localStore: OpenCodeGoLocalStore
    private let network: any NetworkServiceProtocol

    /// - Parameters:
    ///   - cookieHeader: raw opencode.ai `Cookie:` header value (manual
    ///     entry); `OPENCODE_COOKIE` env fallback, then Keychain.
    ///   - workspaceOverride: raw `wrk_…` ID or full
    ///     `https://opencode.ai/workspace/…` URL; `OPENCODE_WORKSPACE_ID`
    ///     env fallback. When set, the web path takes precedence.
    ///   - homeDirectory: override for `~/.local/share/opencode` (test seam).
    ///   - network: injectable network seam for tests.
    public init(
        cookieHeader: String? = nil,
        workspaceOverride: String? = nil,
        homeDirectory: URL? = nil,
        network: any NetworkServiceProtocol = URLSessionNetworkService()
    ) {
        let env = ProcessInfo.processInfo.environment
        self.cookieHeader = cookieHeader
            ?? env["OPENCODE_COOKIE"]
            ?? KeychainCredentials.read(service: "com.symaira.symtune", account: "opencode-cookie")
        self.workspaceOverride = workspaceOverride
            ?? env["OPENCODE_WORKSPACE_ID"]
        self.localStore = OpenCodeGoLocalStore(
            homeDirectory: homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        )
        self.network = network
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "OpenCode Go local history or opencode.ai cookie"
        )
    }

    /// Reads the OpenCode Go auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let env = ProcessInfo.processInfo.environment
        let cookie = env["OPENCODE_COOKIE"]
            ?? KeychainCredentials.read(service: "com.symaira.symtune", account: "opencode-cookie")
        let store = OpenCodeGoLocalStore(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        if let cookie, !cookie.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Cookie configured (OPENCODE_COOKIE or Keychain)",
                source: "keychain"
            )
        }
        if let workspace = env["OPENCODE_WORKSPACE_ID"], !workspace.isEmpty {
            return ExternalAuthState(
                status: .available,
                detail: "Workspace override set (\(workspace.prefix(8))…)",
                source: "env"
            )
        }
        if store.isDetected {
            return ExternalAuthState(
                status: .available,
                detail: "Local OpenCode Go database detected",
                source: "local"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "No OpenCode Go credentials found — set OPENCODE_COOKIE or run OpenCode Go",
            source: nil
        )
    }
}

// MARK: - Local store

/// Locates the OpenCode Go local data files and answers detection questions.
/// Never writes anything.
public struct OpenCodeGoLocalStore: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    /// `~/.local/share/opencode/opencode.db`
    public var databaseURL: URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    private var authURL: URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Whether the DB exists or `auth.json` carries an `opencode-go` key —
    /// used to distinguish "not installed" from "installed, no usage yet".
    public var isDetected: Bool {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            return true
        }
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Errors

enum OpenCodeError: Error, LocalizedError {
    case invalidCredentials
    case network(String)
    case apiError(String)
    case parseFailed(String)
    case historyUnavailable(String)
    case sqliteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "OpenCode session cookie is invalid or expired. Re-import the opencode.ai cookie."
        case .network(let detail):
            return "OpenCode request failed: \(detail)"
        case .apiError(let detail):
            return "OpenCode API error: \(detail)"
        case .parseFailed(let detail):
            return "OpenCode returned an unreadable response: \(detail)"
        case .historyUnavailable(let detail):
            return "OpenCode Go local usage history is unavailable: \(detail)"
        case .sqliteFailed(let detail):
            return "SQLite error reading OpenCode Go usage: \(detail)"
        }
    }
}

// MARK: - Local strategy

/// Reads OpenCode Go assistant cost rows from `opencode.db` (read-only,
/// WAL-aware) and derives the rolling 5h, weekly, and monthly quota
/// percentages. Device-wide by nature — the meter labels say so.
public struct OpenCodeGoLocalStrategy: AIUsageStrategy, Sendable {
    public let source = "local"

    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// Free-tier dollar caps used by OpenCode Go for the three windows.
    static let limits = (session: 12.0, weekly: 30.0, monthly: 60.0)
    static let fiveHours: TimeInterval = 5 * 60 * 60
    static let week: TimeInterval = 7 * 24 * 60 * 60

    public func fetch() async throws -> AIUsageSnapshot {
        try await fetch(now: Date())
    }

    /// Testable seam: computes the windows against an explicit clock.
    func fetch(now: Date) async throws -> AIUsageSnapshot {
        let rows = try readRows()
        return Self.snapshot(rows: rows, now: now)
    }

    // MARK: Row reading

    private func readRows() throws -> [OpenCodeUsageRow] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpenCodeError.historyUnavailable("database not found")
        }
        do {
            return try readRows(immutable: false)
        } catch let failure as SQLiteReadFailure {
            // A clean WAL shutdown can leave the main file in WAL mode with
            // both sidecars gone; immutable mode reads that idle file
            // without recreating sidecars. Active WALs stay on the normal
            // path. Either way the file is opened read-only.
            guard failure.code == SQLITE_CANTOPEN, walSidecarsAreMissing else {
                throw OpenCodeError.sqliteFailed(failure.message)
            }
            do {
                return try readRows(immutable: true)
            } catch let fallback as SQLiteReadFailure {
                throw OpenCodeError.sqliteFailed(fallback.message)
            }
        }
    }

    private var walSidecarsAreMissing: Bool {
        !FileManager.default.fileExists(atPath: databaseURL.path + "-wal") &&
            !FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
    }

    private func readRows(immutable: Bool) throws -> [OpenCodeUsageRow] {
        var db: OpaquePointer?
        let filename = immutable
            ? databaseURL.absoluteURL.absoluteString + "?immutable=1"
            : databaseURL.path
        let flags: Int32 = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            let failure = Self.sqliteFailure(db: db, resultCode: openResult)
            sqlite3_close(db)
            throw failure
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = try hasTable(named: "part", db: db) ? Self.messageAndPartUsageSQL : Self.messageUsageSQL
        var stmt: OpaquePointer?
        let prepareResult = try sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [OpenCodeUsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw Self.sqliteFailure(db: db, resultCode: step)
            }
            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let model = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            rows.append(OpenCodeUsageRow(createdMs: createdMs, cost: cost, model: model))
        }
        return rows
    }

    private func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        let prepareResult = try sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil
        )
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW { return true }
        guard step == SQLITE_DONE else { throw Self.sqliteFailure(db: db, resultCode: step) }
        return false
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        )
    }

    /// Message-only databases (older layouts) carry the cost on the assistant
    /// message row itself.
    static let messageUsageSQL = """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          1 AS requestCount,
          COALESCE(json_extract(data, '$.modelID'), '') AS modelID
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
          AND json_type(data, '$.cost') IN ('integer', 'real')
        """

    /// Newer layouts store the per-step cost on `step-finish` parts; the
    /// message rows cover steps without a costed part.
    static let messageAndPartUsageSQL = """
        WITH provider_messages AS (
          SELECT
            id AS messageID,
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost,
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
            COALESCE(json_extract(data, '$.modelID'), '') AS modelID
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
        )
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          1 AS requestCount,
          m.modelID AS modelID
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost, 1 AS requestCount, modelID
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
        """

    // MARK: Snapshot

    static func snapshot(rows: [OpenCodeUsageRow], now: Date) -> AIUsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStartMs = nowMs - Int64(fiveHours * 1000)
        let weekBounds = weekBounds(now: now)
        let monthBounds = monthBounds(now: now, anchorMs: rows.map(\.createdMs).min())
        let oldestSessionMs = rows
            .filter { $0.createdMs >= sessionStartMs && $0.createdMs <= nowMs }
            .map(\.createdMs)
            .min()

        let sessionCost = sum(rows: rows, in: sessionStartMs...nowMs)
        let weeklyCost = sum(rows: rows, in: weekBounds.startMs...weekBounds.endMs)
        let monthlyCost = sum(rows: rows, in: monthBounds.startMs...monthBounds.endMs)

        var meters: [AIUsageMeter] = []
        let rollingReset: TimeInterval = oldestSessionMs.map {
            max(0, TimeInterval($0 + Int64(fiveHours * 1000) - nowMs) / 1000)
        } ?? 0
        meters.append(AIUsageMeter(
            label: "5h window (this device)",
            used: Decimal(percent(used: sessionCost, limit: limits.session)),
            limit: 100,
            unit: .percent,
            resetsAt: now.addingTimeInterval(rollingReset)
        ))
        meters.append(AIUsageMeter(
            label: "This week (this device)",
            used: Decimal(percent(used: weeklyCost, limit: limits.weekly)),
            limit: 100,
            unit: .percent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(weekBounds.endMs) / 1000)
        ))
        meters.append(AIUsageMeter(
            label: "This month (this device, estimate)",
            used: Decimal(percent(used: monthlyCost, limit: limits.monthly)),
            limit: 100,
            unit: .percent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(monthBounds.endMs) / 1000)
        ))

        return AIUsageSnapshot(
            providerID: "opencode",
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: now,
            source: "local"
        )
    }

    private static func sum(rows: [OpenCodeUsageRow], in range: ClosedRange<Int64>) -> Double {
        rows.filter { range.contains($0.createdMs) }.reduce(0) { $0 + $1.cost }
    }

    private static func percent(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        // Rounded to a whole percent: these are UI-facing meters, and the
        // raw division carries binary floating-point noise (12.000…2).
        return min(100, max(0, (used / limit * 100).rounded()))
    }

    /// The current UTC week (Monday 00:00 UTC → next Monday). Computed with
    /// an explicit UTC calendar so results are deterministic on every
    /// machine, and from the weekday so Sunday lands inside the
    /// just-started week, not the upcoming one.
    static func weekBounds(now: Date) -> (startMs: Int64, endMs: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: now)
        // Gregorian weekday: 1 = Sunday … 7 = Saturday. Days since Monday:
        // Sunday 6, Monday 0, Tuesday 1, … Saturday 5.
        let weekday = calendar.component(.weekday, from: now)
        let daysSinceMonday = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? now
        let end = start.addingTimeInterval(week)
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    /// Monthly window anchored at the earliest local row: if that row falls
    /// in the current UTC month the window is the current month; otherwise
    /// it is the month containing the earliest row (the estimated billing
    /// month). Always an estimate — local history is device-wide.
    static func monthBounds(now: Date, anchorMs: Int64?) -> (startMs: Int64, endMs: Int64) {
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let currentMonth = monthRange(containing: now, calendar: calendar, utc: utc)
        guard let anchorMs else { return currentMonth }
        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
        if calendar.isDate(anchor, equalTo: now, toGranularity: .month) {
            return currentMonth
        }
        return monthRange(containing: anchor, calendar: calendar, utc: utc)
    }

    private static func monthRange(containing date: Date, calendar: Calendar, utc: TimeZone) -> (startMs: Int64, endMs: Int64) {
        var components = calendar.dateComponents(in: utc, from: date)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }
}

/// One costed assistant step from the local OpenCode Go history.
struct OpenCodeUsageRow: Sendable {
    let createdMs: Int64
    let cost: Double
    let model: String
}

/// Internal SQLite failure carrier (message without value material).
private struct SQLiteReadFailure: Error {
    let code: Int32
    let message: String
}

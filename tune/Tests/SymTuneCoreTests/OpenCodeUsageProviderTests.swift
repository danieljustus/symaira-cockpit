import XCTest
import SQLite3
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Fixture database builder

/// One costed assistant message row for the fixture DB.
private struct MessageRow {
    let createdMs: Int64
    let cost: Double
    let model: String
}

/// One costed `step-finish` part row for the fixture DB.
private struct PartRow {
    let messageID: Int64
    let createdMs: Int64
    let cost: Double
}

/// Builds a real opencode.db-shaped SQLite fixture in a temp directory.
private enum OpenCodeFixtureDB {
    static func create(
        in directory: URL,
        withParts: Bool,
        messageJSONs: [MessageRow],
        partJSONs: [PartRow] = []
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK else {
            throw XCTSkip("cannot create fixture DB")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw XCTSkip("fixture setup failed: \(message)")
            }
        }

        try exec("""
        CREATE TABLE message (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          data TEXT,
          time_created INTEGER
        );
        """)
        if withParts {
            try exec("""
            CREATE TABLE part (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              message_id INTEGER,
              data TEXT,
              time_created INTEGER
            );
            """)
        }

        for (i, row) in messageJSONs.enumerated() {
            let json = """
            {"time":{"created":\(row.createdMs)},"cost":\(row.cost),"providerID":"opencode-go",\
            "role":"assistant","modelID":"\(row.model)"}
            """
            try exec("INSERT INTO message (data, time_created) VALUES ('\(json)', \(row.createdMs));")
            _ = i
        }
        for part in partJSONs {
            let json = """
            {"type":"step-finish","cost":\(part.cost),"time":{"created":\(part.createdMs)}}
            """
            try exec("INSERT INTO part (message_id, data, time_created) VALUES (\(part.messageID), '\(json)', \(part.createdMs));")
        }
        return dbURL
    }
}

// MARK: - Tests

final class OpenCodeUsageProviderTests: XCTestCase {
    private func fixture(_ name: String, ext: String = "txt") throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func fixtureText(_ name: String) throws -> String {
        guard let text = String(bytes: try fixture(name), encoding: .utf8) else {
            throw XCTSkip("fixture \(name) is not UTF-8")
        }
        return text
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let now = Date(timeIntervalSince1970: 1_784_289_600) // 2026-08-05T18:00:00Z

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://opencode.ai/_server")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: Local strategy (SQLite)

    func testLocalParsesFixtureDBWithParts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hour: Int64 = 3600
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dbURL = try OpenCodeFixtureDB.create(
            in: dir,
            withParts: true,
            messageJSONs: [
                MessageRow(createdMs: nowMs - hour * 1000, cost: 0.2, model: "gpt-4o"),
                MessageRow(createdMs: nowMs - 2 * hour * 1000, cost: 0.4, model: "claude"),
                MessageRow(createdMs: nowMs - 24 * hour * 1000, cost: 0.6, model: "gpt-4o"),
            ],
            partJSONs: [
                PartRow(messageID: 1, createdMs: nowMs - hour * 1000, cost: 1.2),
                PartRow(messageID: 2, createdMs: nowMs - 2 * hour * 1000, cost: 1.8),
            ]
        )

        let strategy = OpenCodeGoLocalStrategy(databaseURL: dbURL)
        let snapshot = try await strategy.fetch(now: now)

        XCTAssertEqual(snapshot.providerID, "opencode")
        XCTAssertEqual(snapshot.source, "local")
        // Session window: part costs 1.2 + 1.8 = 3.0 of the $12 cap → 25%.
        let session = snapshot.meters.first { $0.label == "5h window (this device)" }
        XCTAssertEqual(session?.used, Decimal(25), "session percent")
        // Week window: all rows fall inside the same UTC week (Jul 13–20),
        // so the sum is the full 3.6 of the $30 cap → 12%.
        let week = snapshot.meters.first { $0.label == "This week (this device)" }
        XCTAssertEqual(week?.used, Decimal(12), "weekly percent")
        // Month window (current month, anchored at the earliest row):
        // same 3.6 of the $60 cap → 6%.
        let month = snapshot.meters.first { $0.label == "This month (this device, estimate)" }
        XCTAssertEqual(month?.used, Decimal(6), "monthly percent")
        XCTAssertNotNil(session?.resetsAt)
        XCTAssertGreaterThan(session?.resetsAt ?? .distantPast, now)
    }

    func testLocalParsesMessageOnlyDatabase() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dbURL = try OpenCodeFixtureDB.create(
            in: dir,
            withParts: false,
            messageJSONs: [MessageRow(createdMs: nowMs - 3600_000, cost: 3.0, model: "gpt-4o")]
        )

        let strategy = OpenCodeGoLocalStrategy(databaseURL: dbURL)
        let snapshot = try await strategy.fetch(now: now)

        // 3.0 of $12 session cap → 25%.
        let session = snapshot.meters.first { $0.label == "5h window (this device)" }
        XCTAssertEqual(session?.used, Decimal(25))
    }

    func testLocalOpenIsReadOnly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dbURL = try OpenCodeFixtureDB.create(
            in: dir,
            withParts: true,
            messageJSONs: [MessageRow(createdMs: nowMs - 3600_000, cost: 1.0, model: "gpt-4o")]
        )
        let before = try Data(contentsOf: dbURL)

        let strategy = OpenCodeGoLocalStrategy(databaseURL: dbURL)
        _ = try await strategy.fetch(now: now)

        let after = try Data(contentsOf: dbURL)
        XCTAssertEqual(before, after, "the database must never be modified")
    }

    func testLocalMissingDatabaseThrowsHistoryUnavailable() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let strategy = OpenCodeGoLocalStrategy(databaseURL: dir.appendingPathComponent("opencode.db"))

        do {
            _ = try await strategy.fetch(now: now)
            XCTFail("expected an error")
        } catch let error as OpenCodeError {
            guard case .historyUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testLocalStoreDetection() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OpenCodeGoLocalStore(homeDirectory: dir)
        XCTAssertFalse(store.isDetected)

        _ = try OpenCodeFixtureDB.create(
            in: dir.appendingPathComponent(".local/share/opencode"),
            withParts: false,
            messageJSONs: [MessageRow(createdMs: 1, cost: 1.0, model: "gpt-4o")]
        )
        XCTAssertTrue(store.isDetected)
    }

    // MARK: Web strategy

    func testWorkspaceOverrideNormalization() {
        XCTAssertEqual(OpenCodeWebStrategy.normalizeWorkspaceID("wrk_abc123"), "wrk_abc123")
        XCTAssertEqual(
            OpenCodeWebStrategy.normalizeWorkspaceID("https://opencode.ai/workspace/wrk_abc123/billing"),
            "wrk_abc123"
        )
        XCTAssertEqual(
            OpenCodeWebStrategy.normalizeWorkspaceID("  https://opencode.ai/workspace/wrk_xyz987  "),
            "wrk_xyz987"
        )
        XCTAssertEqual(OpenCodeWebStrategy.normalizeWorkspaceID("text wrk_embedded42 more"), "wrk_embedded42")
        XCTAssertNil(OpenCodeWebStrategy.normalizeWorkspaceID(nil))
        XCTAssertNil(OpenCodeWebStrategy.normalizeWorkspaceID(""))
        XCTAssertNil(OpenCodeWebStrategy.normalizeWorkspaceID("https://opencode.ai/workspace/"))
    }

    func testWebStrategyUsesWorkspaceOverrideWithoutLookup() async throws {
        // With an override the strategy must skip the workspaces call and go
        // straight to the subscription endpoint.
        let network = FakeNetwork(result: .success((
            try fixture("opencode-subscription-json"),
            httpResponse(200)
        )))
        let strategy = OpenCodeWebStrategy(
            cookieHeader: "session=test-cookie",
            workspaceOverride: "wrk_abc123",
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "web")
        XCTAssertEqual(network.lastRequest?.url?.query?.contains("id=7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"), true)
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Cookie"), "session=test-cookie")
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "X-Server-Id"), "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4")
    }

    func testWebParsesJSONSubscription() async throws {
        let text = try fixtureText("opencode-subscription-json")
        let snapshot = try OpenCodeWebStrategy.parseSubscription(text: text, now: now)

        let rolling = snapshot.meters.first { $0.label == "5h window" }
        XCTAssertEqual(rolling?.used, Decimal(12.34))
        XCTAssertEqual(rolling?.unit, .percent)
        let rollingReset = try XCTUnwrap(rolling?.resetsAt)
        XCTAssertEqual(rollingReset.timeIntervalSince(now), 3600.0, accuracy: 1.0)
        let weekly = snapshot.meters.first { $0.label == "This week" }
        XCTAssertEqual(weekly?.used, Decimal(45.6))
        let weeklyReset = try XCTUnwrap(weekly?.resetsAt)
        XCTAssertEqual(weeklyReset.timeIntervalSince(now), 86400.0, accuracy: 1.0)
    }

    func testWebParsesJSLiteralSubscriptionViaRegex() async throws {
        let text = try fixtureText("opencode-subscription-js")
        let snapshot = try OpenCodeWebStrategy.parseSubscription(text: text, now: now)

        let rolling = snapshot.meters.first { $0.label == "5h window" }
        XCTAssertEqual(rolling?.used, Decimal(12.34))
        let rollingReset = try XCTUnwrap(rolling?.resetsAt)
        XCTAssertEqual(rollingReset.timeIntervalSince(now), 3600.0, accuracy: 1.0)
        let weekly = snapshot.meters.first { $0.label == "This week" }
        XCTAssertEqual(weekly?.used, Decimal(45.6))
    }

    func testWebFetchesWorkspaceIDWhenNoOverride() async throws {
        let workspaces = try fixtureText("opencode-workspaces")
        let subscription = try fixtureText("opencode-subscription-json")
        let network = ScriptedNetwork(results: [
            .success((Data(workspaces.utf8), httpResponse(200))),
            .success((Data(subscription.utf8), httpResponse(200))),
        ])
        let strategy = OpenCodeWebStrategy(
            cookieHeader: "session=test-cookie",
            workspaceOverride: nil,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "web")
        XCTAssertEqual(network.requestCount, 2)
        let first = network.requests[0]
        XCTAssertEqual(first.url?.query?.contains("id=def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"), true)
    }

    func testWebRejectsSignedOutPayload() async {
        let network = FakeNetwork(result: .success((
            Data("{\"error\":\"please sign in\"}".utf8),
            httpResponse(200)
        )))
        let strategy = OpenCodeWebStrategy(
            cookieHeader: "session=stale",
            workspaceOverride: "wrk_abc123",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as OpenCodeError {
            guard case .invalidCredentials = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Provider strategy ordering

    func testProviderUnscopedUsesLocalFirst() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        _ = try OpenCodeFixtureDB.create(
            in: dir.appendingPathComponent(".local/share/opencode"),
            withParts: false,
            messageJSONs: [MessageRow(createdMs: nowMs - 3600_000, cost: 1.0, model: "gpt-4o")]
        )
        let provider = OpenCodeUsageProvider(
            cookieHeader: nil,
            workspaceOverride: nil,
            homeDirectory: dir
        )
        XCTAssertTrue(provider.isConfigured)
        XCTAssertEqual(provider.strategies.map(\.source), ["local"])
    }

    func testProviderScopedUsesWebFirst() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        _ = try OpenCodeFixtureDB.create(
            in: dir.appendingPathComponent(".local/share/opencode"),
            withParts: false,
            messageJSONs: [MessageRow(createdMs: nowMs - 3600_000, cost: 1.0, model: "gpt-4o")]
        )
        let provider = OpenCodeUsageProvider(
            cookieHeader: "session=abc",
            workspaceOverride: nil,
            homeDirectory: dir
        )
        XCTAssertEqual(provider.strategies.map(\.source), ["web", "local"])
    }

    func testProviderUnconfiguredWithoutAnySource() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = OpenCodeUsageProvider(
            cookieHeader: nil,
            workspaceOverride: nil,
            homeDirectory: dir
        )
        XCTAssertFalse(provider.isConfigured)
        XCTAssertTrue(provider.strategies.isEmpty)
    }
}

// MARK: - Scripted network (multi-request seam)

private final class ScriptedNetwork: NetworkServiceProtocol, @unchecked Sendable {
    var results: [Result<(Data, URLResponse), Error>]
    var requests: [URLRequest] = []

    init(results: [Result<(Data, URLResponse), Error>]) {
        self.results = results
    }

    var requestCount: Int { requests.count }

    func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        try await fetchData(from: URLRequest(url: url))
    }

    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try results.removeFirst().get()
    }
}

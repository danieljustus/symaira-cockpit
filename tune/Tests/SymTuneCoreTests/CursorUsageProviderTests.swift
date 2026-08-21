import XCTest
import SQLite3
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Fixture database builder

/// Builds a real Cursor `state.vscdb`-shaped SQLite fixture.
private enum CursorFixtureDB {
    static func create(
        in directory: URL,
        token: String?,
        asBlob: Bool = false
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("state.vscdb")
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

        try exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);")
        if let token {
            if asBlob {
                let hex = token.utf8.map { String(format: "%02X", $0) }.joined()
                try exec("INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', X'\(hex)');")
            } else {
                try exec("INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', '\(token)');")
            }
        }
        return dbURL
    }
}

// MARK: - JWT helper

private enum TestJWT {
    /// Builds a syntactically valid JWT with the given payload claims.
    static func make(payload: [String: Any]) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = #"{"alg":"none"}"#
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return base64URL(Data(header.utf8)) + "." + base64URL(payloadData) + ".sig"
    }
}

// MARK: - Tests

final class CursorUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func validToken() -> String {
        TestJWT.make(payload: [
            "sub": "auth0|tenant|user_abc123",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
        ])
    }

    // MARK: Web strategy

    func testParsesUsageSummaryFixture() async throws {
        let network = FakeNetwork(result: .success((try fixture("cursor-usage-summary"), httpResponse(200))))
        let strategy = CursorWebStrategy(cookieHeader: "WorkosCursorSessionToken=user_abc123%3A%3Atoken", network: network)

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "cursor")
        XCTAssertEqual(snapshot.source, "web")
        let plan = snapshot.meters.first { $0.label == "Plan usage" }
        XCTAssertEqual(plan?.used, Decimal(95))
        XCTAssertEqual(plan?.unit, .percent)
        let reset = try XCTUnwrap(plan?.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_788_220_800, accuracy: 1) // 2026-09-01T00:00:00Z
        XCTAssertEqual(snapshot.meters.first { $0.label == "Auto usage" }?.used, Decimal(85))
        XCTAssertEqual(snapshot.meters.first { $0.label == "API usage" }?.used, Decimal(15))
        let onDemand = snapshot.meters.first { $0.label == "On-demand usage" }
        XCTAssertEqual(onDemand?.used, Decimal(734))
        XCTAssertEqual(onDemand?.limit, Decimal(10000))
        XCTAssertEqual(onDemand?.unit, .currency("USD"))
    }

    func testWebStrategySendsCookieHeader() async throws {
        let network = FakeNetwork(result: .success((try fixture("cursor-usage-summary"), httpResponse(200))))
        let strategy = CursorWebStrategy(cookieHeader: "WorkosCursorSessionToken=user_abc123%3A%3Atok", network: network)

        _ = try await strategy.fetch()

        XCTAssertEqual(
            network.lastRequest?.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_abc123%3A%3Atok"
        )
        XCTAssertEqual(network.lastRequest?.url?.host, "cursor.com")
    }

    func testWebStrategyRejectsInvalidSessionWithoutLeakingCookie() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = CursorWebStrategy(cookieHeader: "WorkosCursorSessionToken=user_abc123%3A%3Asecret-token", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as CursorError {
            guard case .invalidCredentials = error else {
                return XCTFail("unexpected error: \(error)")
            }
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.contains("secret-token"), "session material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testWebStrategyHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "30"])
        )))
        let strategy = CursorWebStrategy(cookieHeader: "WorkosCursorSessionToken=user_abc123%3A%3Atoken", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "cursor")
            XCTAssertEqual(retryAfter, 30)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testWebStrategyHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = CursorWebStrategy(cookieHeader: "WorkosCursorSessionToken=user_abc123%3A%3Atoken", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "cursor")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Cursor.app local auth

    func testAppAuthSessionDerivesCookieHeader() throws {
        let token = validToken()
        let session = CursorAppAuthSession(accessToken: token)
        XCTAssertTrue(session.isUsable)
        XCTAssertEqual(try session.userID(), "user_abc123")
        XCTAssertEqual(try session.cookieHeader(), "WorkosCursorSessionToken=user_abc123%3A%3A\(token)")
    }

    func testAppAuthSessionRejectsExpiredToken() {
        let token = TestJWT.make(payload: [
            "sub": "auth0|tenant|user_abc123",
            "exp": Date().addingTimeInterval(-100).timeIntervalSince1970,
        ])
        XCTAssertFalse(CursorAppAuthSession(accessToken: token).isUsable)
    }

    func testAppAuthSessionRejectsGarbage() {
        XCTAssertFalse(CursorAppAuthSession(accessToken: "not-a-jwt").isUsable)
        XCTAssertFalse(CursorAppAuthSession(accessToken: "").isUsable)
    }

    func testAppAuthStoreReadsTextToken() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: validToken())

        let store = CursorAppAuthStore(dbPath: dbURL.path)
        let session = try XCTUnwrap(store.loadSession())
        XCTAssertTrue(session.isUsable)
    }

    func testAppAuthStoreReadsBlobToken() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: validToken(), asBlob: true)

        let store = CursorAppAuthStore(dbPath: dbURL.path)
        XCTAssertNotNil(store.loadSession())
    }

    func testAppAuthStoreMissingKeyReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: nil)

        let store = CursorAppAuthStore(dbPath: dbURL.path)
        XCTAssertNil(store.loadSession())
    }

    func testAppAuthStoreIsReadOnly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: validToken())
        let before = try Data(contentsOf: dbURL)

        let store = CursorAppAuthStore(dbPath: dbURL.path)
        _ = store.loadSession()

        let after = try Data(contentsOf: dbURL)
        XCTAssertEqual(before, after, "the state database must never be modified")
    }

    func testLocalAuthStrategyFetchesWithDerivedCookie() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: validToken())
        let session = try XCTUnwrap(CursorAppAuthStore(dbPath: dbURL.path).loadSession())

        let network = FakeNetwork(result: .success((try fixture("cursor-usage-summary"), httpResponse(200))))
        let strategy = CursorLocalAuthStrategy(session: session, network: network)

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "local")
        let cookie = try XCTUnwrap(network.lastRequest?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.hasPrefix("WorkosCursorSessionToken=user_abc123%3A%3A"), cookie)
    }

    // MARK: Provider ordering

    func testProviderWebFirstThenLocal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = try CursorFixtureDB.create(in: dir, token: validToken())

        let provider = CursorUsageProvider(
            cookieHeader: "WorkosCursorSessionToken=manual",
            vscdbPath: dbURL.path
        )
        XCTAssertEqual(provider.strategies.map(\.source), ["web", "local"])
    }

    func testProviderCookieOnly() {
        let provider = CursorUsageProvider(
            cookieHeader: "WorkosCursorSessionToken=manual",
            vscdbPath: "/nonexistent/state.vscdb"
        )
        XCTAssertEqual(provider.strategies.map(\.source), ["web"])
        XCTAssertTrue(provider.isConfigured)
    }

    func testProviderUnconfiguredWithoutAnySession() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = CursorUsageProvider(
            cookieHeader: nil,
            vscdbPath: dir.appendingPathComponent("state.vscdb").path
        )
        XCTAssertFalse(provider.isConfigured)
        XCTAssertTrue(provider.strategies.isEmpty)
    }
}

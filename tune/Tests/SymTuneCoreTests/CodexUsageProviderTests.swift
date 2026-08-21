import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class CodexUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesWhamUsage() async throws {
        let network = FakeNetwork(result: .success((try fixture("codex-wham-usage"), httpResponse(200))))
        let strategy = CodexOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            accountLabel: "/Users/test/.codex",
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "codex")
        XCTAssertEqual(snapshot.source, "oauth")
        let primary = snapshot.meters.first { $0.label == "5h" }
        let secondary = snapshot.meters.first { $0.label == "1w" }
        XCTAssertEqual(primary?.used, Decimal(25))
        XCTAssertEqual(primary?.limit, Decimal(100))
        XCTAssertEqual(primary?.unit, .percent)
        XCTAssertNotNil(primary?.resetsAt)
        XCTAssertEqual(secondary?.used, Decimal(200))
        XCTAssertEqual(secondary?.limit, Decimal(800))
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Codex Spark Weekly" })
    }

    func testProviderUnconfiguredWithoutToken() {
        let provider = CodexUsageProvider(
            homeDirectory: "/nonexistent",
            accessToken: ""
        )
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithToken() {
        let provider = CodexUsageProvider(
            homeDirectory: "/nonexistent",
            accessToken: "sk-test"
        )
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: Auth store (strictly read-only)

    func testAuthStoreReadsAccessToken() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = """
        {"access_token": "sk-ant-oat-synthetic", "openai_login": {"email": "dev@example.com", "plan": "pro"}}
        """
        let url = tmp.appendingPathComponent("auth.json")
        try store.write(to: url, atomically: true, encoding: .utf8)

        let before = try Data(contentsOf: url)
        let token = CodexAuthStore().readAccessToken(home: tmp.path)
        let after = try Data(contentsOf: url)

        XCTAssertEqual(token, "sk-ant-oat-synthetic")
        XCTAssertEqual(before, after, "auth.json must stay byte-identical after a read")
    }

    func testAuthStoreIdentityFromClaims() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = """
        {"access_token": "sk-test", "openai_login": {"email": "dev@example.com", "plan_type": "pro"}}
        """
        let url = tmp.appendingPathComponent("auth.json")
        try store.write(to: url, atomically: true, encoding: .utf8)

        let identity = CodexAuthStore().identity(home: tmp.path)
        XCTAssertEqual(identity?.email, "dev@example.com")
        XCTAssertEqual(identity?.plan, "pro")
    }

    func testAuthStoreIgnoresMissingFile() {
        XCTAssertNil(CodexAuthStore().readAccessToken(home: "/nonexistent-home"))
        XCTAssertNil(CodexAuthStore().identity(home: "/nonexistent-home"))
    }

    // MARK: Errors never leak token material

    func testAuthErrorIsUnderstandableWithoutTokenMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = CodexOAuthStrategy(
            accessToken: "sk-ant-oat-secret-token-material",
            accountLabel: "test",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .notConfigured(let id) = error else {
                XCTFail("expected .notConfigured, got \(error)")
                return
            }
            XCTAssertEqual(id, "codex")
            XCTAssertFalse(error.localizedDescription.contains("sk-ant"), "token material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAuthorizationHeaderUsesBearerToken() async throws {
        let network = FakeNetwork(result: .success((try fixture("codex-wham-usage"), httpResponse(200))))
        let strategy = CodexOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            accountLabel: "test",
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-test")
        XCTAssertEqual(network.lastRequest?.url?.path, "/backend-api/wham/usage")
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "17"])
        )))
        let strategy = CodexOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            accountLabel: "test",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "codex")
            XCTAssertEqual(retryAfter, 17)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = CodexOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            accountLabel: "test",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "codex")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

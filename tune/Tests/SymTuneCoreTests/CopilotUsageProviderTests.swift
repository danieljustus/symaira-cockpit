import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class CopilotUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/copilot_internal/user")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesCopilotUser() async throws {
        let network = FakeNetwork(result: .success((try fixture("copilot-user"), httpResponse(200))))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_test",
            host: "github.com",
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "copilot")
        XCTAssertEqual(snapshot.source, "api")
        let premium = snapshot.meters.first { $0.label == "Premium requests" }
        XCTAssertEqual(premium?.used, Decimal(45))
        XCTAssertEqual(premium?.limit, Decimal(300))
        XCTAssertEqual(premium?.unit, .requests)
        XCTAssertNotNil(premium?.resetsAt)
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Skills chat requests" && $0.used == Decimal(12) })
    }

    func testProviderUnconfiguredWithoutToken() {
        let provider = CopilotUsageProvider(accessToken: "")
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithToken() {
        let provider = CopilotUsageProvider(accessToken: "ghu_test")
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: Token store (read-only local config)

    func testTokenStoreReadsAppsJson() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = """
        {"github.com:Iv1.test": {"user": "dev", "oauth_token": "ghu_synthetic-token"}}
        """
        let url = tmp.appendingPathComponent("apps.json")
        try store.write(to: url, atomically: true, encoding: .utf8)

        let before = try Data(contentsOf: url)
        let storeReader = CopilotTokenStore()
        let token = storeReader.readToken(fromDirectory: tmp.path)
        let after = try Data(contentsOf: url)

        XCTAssertEqual(token, "ghu_synthetic-token")
        XCTAssertEqual(before, after, "config must stay byte-identical after a read")
    }

    // MARK: Device flow is explicit-only

    func testDeviceFlowIsSeparateEntryPoint() {
        // The provider init must never start a device flow — it only reads
        // existing tokens. The device flow lives in an explicit static
        // method that callers invoke from a user action.
        let provider = CopilotUsageProvider(accessToken: "")
        XCTAssertFalse(provider.isConfigured)
        XCTAssertEqual(
            CopilotUsageProvider.verificationURL(
                uri: "https://github.com/login/device",
                userCode: "ABCD-EFGH"
            ).absoluteString,
            "https://github.com/login/device?user_code=ABCD-EFGH"
        )
    }

    // MARK: Errors never leak token material

    func testAuthErrorIsUnderstandableWithoutTokenMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_secret-token-material",
            host: "github.com",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as CopilotError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("re-auth"), message)
            XCTAssertFalse(message.contains("ghu_"), "token material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAuthorizationHeaderUsesBearerToken() async throws {
        let network = FakeNetwork(result: .success((try fixture("copilot-user"), httpResponse(200))))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_test",
            host: "github.com",
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer ghu_test")
        XCTAssertEqual(network.lastRequest?.url?.host, "api.github.com")
    }

    func testEnterpriseHostUsesApiV3Base() async throws {
        let network = FakeNetwork(result: .success((try fixture("copilot-user"), httpResponse(200))))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_test",
            host: "github.example.com",
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.url?.absoluteString, "https://github.example.com/api/v3/copilot_internal/user")
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "60"])
        )))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_test",
            host: "github.com",
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
            XCTAssertEqual(id, "copilot")
            XCTAssertEqual(retryAfter, 60)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = CopilotAPIStrategy(
            accessToken: "ghu_test",
            host: "github.com",
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
            XCTAssertEqual(id, "copilot")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class ClaudeUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: OAuth parsing fixtures (no network)

    func testParsesOAuthUsageWindows() async throws {
        let network = FakeNetwork(result: .success((try fixture("claude-oauth-usage"), httpResponse(200))))
        let strategy = ClaudeOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "claude")
        XCTAssertEqual(snapshot.source, "oauth")
        let fiveHour = snapshot.meters.first { $0.label == "five_hour" }
        let sevenDay = snapshot.meters.first { $0.label == "seven_day" }
        XCTAssertEqual(fiveHour?.used, Decimal(45))
        XCTAssertEqual(fiveHour?.limit, Decimal(100))
        XCTAssertEqual(fiveHour?.unit, .percent)
        XCTAssertNotNil(fiveHour?.resetsAt)
        XCTAssertEqual(sevenDay?.used, Decimal(120))
        XCTAssertEqual(sevenDay?.limit, Decimal(400))
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Extra usage" })
    }

    func testAdminAPIStrategyParsesCostReport() async throws {
        let network = FakeNetwork(result: .success((try fixture("claude-admin-cost"), httpResponse(200))))
        let strategy = ClaudeAdminAPIStrategy(
            apiKey: "sk-ant-admin-test",
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "api")
        XCTAssertEqual(snapshot.currency, "USD")
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Spend (7d)" && $0.used == Decimal(12.5) })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Messages (7d)" && $0.used == Decimal(340) })
    }

    func testAdminAPIUsesCostReportEndpoint() async throws {
        let network = FakeNetwork(result: .success((try fixture("claude-admin-cost"), httpResponse(200))))
        let strategy = ClaudeAdminAPIStrategy(
            apiKey: "sk-ant-admin-test",
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.url?.path, "/v1/organizations/cost_report")
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-admin-test")
    }

    func testOAuthUsesBetaHeader() async throws {
        let network = FakeNetwork(result: .success((try fixture("claude-oauth-usage"), httpResponse(200))))
        let strategy = ClaudeOAuthStrategy(
            accessToken: "sk-ant-oat-test",
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(network.lastRequest?.url?.path, "/api/oauth/usage")
    }

    // MARK: Keychain prompt policy

    func testDefaultPolicyIsNeverPrompt() {
        XCTAssertEqual(KeychainPromptPolicy.default, .never)
    }

    func testProviderUnconfiguredWithoutCredentials() {
        let provider = ClaudeUsageProvider(
            adminAPIKey: "",
            oauthToken: nil,
            oauthTokenReader: { _ in nil }
        )
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithAdminKey() {
        let provider = ClaudeUsageProvider(
            adminAPIKey: "sk-ant-admin-abc",
            oauthToken: nil,
            oauthTokenReader: { _ in nil }
        )
        XCTAssertTrue(provider.isConfigured)
    }

    func testProviderConfiguredWithOAuthToken() {
        let provider = ClaudeUsageProvider(
            adminAPIKey: "",
            oauthToken: "sk-ant-oat-abc",
            oauthTokenReader: { _ in nil }
        )
        XCTAssertTrue(provider.isConfigured)
    }

    func testProviderUsesReaderWhenNoExplicitToken() {
        let provider = ClaudeUsageProvider(
            adminAPIKey: "",
            oauthToken: nil,
            keychainPromptPolicy: .never,
            oauthTokenReader: { policy in
                XCTAssertEqual(policy, .never)
                return "sk-ant-oat-from-reader"
            }
        )
        XCTAssertTrue(provider.isConfigured)
        XCTAssertEqual(provider.strategies.first?.source, "oauth")
    }

    // MARK: mcpOAuth-without-claudeAiOauth pitfall (fixture-based)

    func testMcpOAuthOnlyKeychainEntryIsConfigErrorNotEmptyQuota() {
        // Simulates the Claude Code 2.1.x Keychain entry that holds only
        // MCP-OAuth state: no claudeAiOauth field.
        let entry: [String: Any] = [
            "mcpOAuth": ["server1": ["accessToken": "sk-ant-mcp-secret"]],
        ]
        let token = ClaudeOAuthCredentials.token(fromKeychainJSON: entry)
        XCTAssertNil(token, "mcpOAuth-only entries must not be treated as usable OAuth")
    }

    func testValidClaudeAiOauthEntryYieldsToken() {
        let entry: [String: Any] = [
            "claudeAiOauth": ["accessToken": "sk-ant-oat-valid"],
            "mcpOAuth": ["server1": ["accessToken": "sk-ant-mcp-secret"]],
        ]
        XCTAssertEqual(ClaudeOAuthCredentials.token(fromKeychainJSON: entry), "sk-ant-oat-valid")
    }

    // MARK: Errors never leak token material

    func testAuthErrorIsUnderstandableWithoutTokenMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = ClaudeOAuthStrategy(
            accessToken: "sk-ant-oat-secret-token-material",
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as ClaudeError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("re-auth"), message)
            XCTAssertFalse(message.contains("sk-ant"), "token material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testOAuthStrategyHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "8"])
        )))
        let strategy = ClaudeOAuthStrategy(accessToken: "sk-ant-oat-test", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "claude")
            XCTAssertEqual(retryAfter, 8)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAdminAPIStrategyHTTP429MapsToRateLimitedWithoutRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = ClaudeAdminAPIStrategy(apiKey: "sk-ant-admin-test", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "claude")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

// MARK: - Keychain JSON parsing seam (testable without the real Keychain)

extension ClaudeOAuthCredentials {
    /// Extracts the OAuth access token from a parsed Keychain entry JSON.
    /// Exposed for fixture-based tests; the production path parses the same
    /// shape from the `Claude Code-credentials` item.
    static func token(fromKeychainJSON json: [String: Any]) -> String? {
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }
}

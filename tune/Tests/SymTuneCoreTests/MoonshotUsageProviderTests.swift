import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class MoonshotUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.moonshot.ai/v1/users/me/balance")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesInternationalBalance() async throws {
        let network = FakeNetwork(result: .success((try fixture("moonshot-balance-ai"), httpResponse(200))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-test",
            region: .international,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "moonshot")
        XCTAssertEqual(snapshot.source, "api")
        XCTAssertEqual(snapshot.currency, "USD")
        XCTAssertEqual(snapshot.balance, Decimal(42.5))
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Cash balance" })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Voucher balance" })
        // USD region must not leak CNY amounts across the currency boundary.
        XCTAssertEqual(snapshot.meters.first { $0.label == "Cash balance" }?.unit, .currency("USD"))
    }

    func testParsesChinaBalanceWithCNY() async throws {
        let network = FakeNetwork(result: .success((try fixture("moonshot-balance-cn"), httpResponse(200))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-cn-test",
            region: .china,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.currency, "CNY")
        XCTAssertEqual(snapshot.balance, Decimal(88.88))
        XCTAssertEqual(snapshot.meters.first { $0.label == "Cash balance" }?.unit, .currency("CNY"))
        XCTAssertFalse(snapshot.meters.contains { $0.label == "Voucher balance" })
    }

    func testRegionDefaultsToInternational() {
        let provider = MoonshotUsageProvider(
            apiKey: "sk-test",
            region: nil
        )
        XCTAssertEqual(provider.strategies.count, 1)
    }

    func testProviderUnconfiguredWithoutKey() {
        let provider = MoonshotUsageProvider(
            apiKey: "",
            region: .international
        )
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithKey() {
        let provider = MoonshotUsageProvider(
            apiKey: "sk-moonshot-abc",
            region: .international
        )
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: Errors never leak key material

    func testAuthErrorIsUnderstandableWithoutKeyMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-secret-key-material",
            region: .international,
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
            XCTAssertEqual(id, "moonshot")
            XCTAssertFalse(error.localizedDescription.contains("sk-moonshot"), "key material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAuthorizationHeaderUsesBearerToken() async throws {
        let network = FakeNetwork(result: .success((try fixture("moonshot-balance-ai"), httpResponse(200))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-test-key",
            region: .international,
            network: network
        )

        _ = try await strategy.fetch()

        let auth = network.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-moonshot-test-key")
        XCTAssertEqual(network.lastRequest?.url?.host, "api.moonshot.ai")
    }

    func testChinaRegionUsesCNHost() async throws {
        let network = FakeNetwork(result: .success((try fixture("moonshot-balance-cn"), httpResponse(200))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-test",
            region: .china,
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.url?.host, "api.moonshot.cn")
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "5"])
        )))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-test",
            region: .international,
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
            XCTAssertEqual(id, "moonshot")
            XCTAssertEqual(retryAfter, 5)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = MoonshotAPIStrategy(
            apiKey: "sk-moonshot-test",
            region: .international,
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
            XCTAssertEqual(id, "moonshot")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

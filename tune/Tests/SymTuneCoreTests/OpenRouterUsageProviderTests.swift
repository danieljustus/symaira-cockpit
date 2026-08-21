import XCTest
@testable import SymTuneCore

// MARK: - Fake network

/// Scripted network seam: returns fixture data or a canned error.
final class FakeNetwork: NetworkServiceProtocol, @unchecked Sendable {
    var result: Result<(Data, URLResponse), Error>
    var lastRequest: URLRequest?

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        try await fetchData(from: URLRequest(url: url))
    }

    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return try result.get()
    }
}

/// Mutable box so a test can change the value a captured `@Sendable` resolver
/// returns between accesses (single-threaded test; `@unchecked` is safe here).
private final class KeyBox: @unchecked Sendable {
    var value: String
    init(_ value: String) {
        self.value = value
    }
}

// MARK: - Tests

final class OpenRouterUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://openrouter.ai/api/v1/auth/key")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesCreditsResponse() async throws {
        let network = FakeNetwork(result: .success((try fixture("openrouter-credits"), httpResponse(200))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "openrouter")
        XCTAssertEqual(snapshot.source, "api")
        XCTAssertEqual(snapshot.currency, "USD")
        XCTAssertEqual(snapshot.balance, 42.75)
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Key limit" })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Requests" })
    }

    func testParsesResponseWithoutLimit() async throws {
        let network = FakeNetwork(result: .success((try fixture("openrouter-no-limit"), httpResponse(200))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.balance, nil)
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Spend" })
        XCTAssertFalse(snapshot.meters.contains { $0.label == "Key limit" })
    }

    func testOmitsRequestsMeterWhenRateLimitIsNotReal() async throws {
        let network = FakeNetwork(result: .success((try fixture("openrouter-no-request-limit"), httpResponse(200))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertFalse(snapshot.meters.contains { $0.label == "Requests" })
    }

    func testKeepsRequestsMeterWhenRateLimitIsReal() async throws {
        let network = FakeNetwork(result: .success((try fixture("openrouter-credits"), httpResponse(200))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        let snapshot = try await strategy.fetch()

        let meter = snapshot.meters.first { $0.label == "Requests" }
        XCTAssertNotNil(meter)
        XCTAssertEqual(meter?.limit, 500)
    }

    func testProviderUnconfiguredWithoutKey() {
        let provider = OpenRouterUsageProvider(
            apiKey: "",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!
        )
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithKey() {
        let provider = OpenRouterUsageProvider(
            apiKey: "sk-or-v1-abc",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!
        )
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: Lazy credential resolution (issue #324)

    func testIsConfiguredFollowsLiveCredentialChanges() {
        // A mutable box behind the internal resolver seam: flipping its value
        // must flip isConfigured without rebuilding the provider.
        let box = KeyBox("")
        let provider = OpenRouterUsageProvider(
            keyResolver: { box.value },
            baseURL: URL(string: "https://openrouter.ai/api/v1")!
        )

        XCTAssertFalse(provider.isConfigured)

        box.value = "sk-or-v1-live"
        XCTAssertTrue(provider.isConfigured, "key added must take effect without a rebuild")

        box.value = ""
        XCTAssertFalse(provider.isConfigured, "key removed must take effect without a rebuild")
    }

    func testStrategiesFollowLiveCredentialChanges() {
        let box = KeyBox("")
        let provider = OpenRouterUsageProvider(
            keyResolver: { box.value },
            baseURL: URL(string: "https://openrouter.ai/api/v1")!
        )

        XCTAssertTrue(provider.strategies.isEmpty)
        box.value = "sk-or-v1-live"
        XCTAssertEqual(provider.strategies.count, 1)
        box.value = ""
        XCTAssertTrue(provider.strategies.isEmpty)
    }

    // MARK: Errors never leak key material

    func testAuthErrorIsUnderstandableWithoutKeyMaterial() async throws {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-secret-key-material",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
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
            XCTAssertEqual(id, "openrouter")
            XCTAssertFalse(error.localizedDescription.contains("sk-or-v1"), "key material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNetworkErrorWrapsWithoutLeakingKey() async throws {
        struct Boom: Error {}
        let network = FakeNetwork(result: .failure(Boom()))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-secret-key-material",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageHTTPError {
            guard case .network = error else {
                XCTFail("expected .network, got \(error)")
                return
            }
            XCTAssertTrue(error.errorDescription?.contains("request failed") == true)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAuthorizationHeaderUsesBearerToken() async throws {
        let network = FakeNetwork(result: .success((try fixture("openrouter-credits"), httpResponse(200))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test-key",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        _ = try await strategy.fetch()

        let auth = network.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-or-v1-test-key")
        let title = network.lastRequest?.value(forHTTPHeaderField: "X-Title")
        XCTAssertEqual(title, "symtune")
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    /// Drives the real `OpenRouterAPIStrategy` through a stubbed network
    /// service returning HTTP 429 with a `Retry-After` header, and asserts
    /// the thrown error is `AIUsageError.rateLimited` carrying the parsed
    /// delay — not the provider's generic `httpStatus` error. This is what
    /// lets `AIUsageService` actually engage the backoff it already
    /// implements (`if case .rateLimited(_, let retryAfter) = error { ... }`).
    func testHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "42"])
        )))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
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
            XCTAssertEqual(id, "openrouter")
            XCTAssertEqual(retryAfter, 42)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Same 429 mapping, but without a `Retry-After` header: `retryAfter`
    /// must come through as `nil` (the caller — `AIUsageService` — supplies
    /// its own default backoff in that case) rather than a bogus value.
    func testHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
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
            XCTAssertEqual(id, "openrouter")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// An unparseable `Retry-After` value (not delta-seconds) must degrade
    /// to `nil` rather than crash or propagate garbage.
    func testHTTP429WithUnparseableRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])
        )))
        let strategy = OpenRouterAPIStrategy(
            apiKey: "sk-or-v1-test",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(_, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

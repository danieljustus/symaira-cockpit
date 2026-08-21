import XCTest
@testable import SymTuneCore

// MARK: - Fakes

/// Scripted strategy for provider tests (no network, no credentials).
final class FakeStrategy: AIUsageStrategy, @unchecked Sendable {
    enum Outcome: Sendable {
        case success(AIUsageSnapshot)
        case failure(AIUsageError)
        case sleepThenSuccess(TimeInterval, AIUsageSnapshot)
        case sleepThenFailure(TimeInterval, AIUsageError)
    }

    let source: String
    var outcome: Outcome
    private let lock = NSLock()
    private var invocationCount = 0

    init(source: String, outcome: Outcome) {
        self.source = source
        self.outcome = outcome
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }

    func fetch() async throws -> AIUsageSnapshot {
        lock.withLock { invocationCount += 1 }
        switch outcome {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        case .sleepThenSuccess(let seconds, let snapshot):
            try await Task.sleep(for: .seconds(seconds))
            return snapshot
        case .sleepThenFailure(let seconds, let error):
            try await Task.sleep(for: .seconds(seconds))
            throw error
        }
    }
}

final class FakeProvider: AIUsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let isConfigured: Bool
    let strategies: [any AIUsageStrategy]
    let directError: AIUsageError?
    private let lock = NSLock()
    private var invocationCount = 0

    init(
        id: String,
        displayName: String = "Fake",
        isConfigured: Bool = true,
        strategies: [any AIUsageStrategy],
        directError: AIUsageError? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isConfigured = isConfigured
        self.strategies = strategies
        self.directError = directError
    }

    var calls: Int {
        lock.withLock { invocationCount }
    }

    func fetch() async throws -> AIUsageSnapshot {
        lock.withLock { invocationCount += 1 }
        if let directError {
            throw directError
        }
        return try await AIUsageStrategyChain.run(strategies)
    }
}

// MARK: - Tests

final class AIUsageServiceTests: XCTestCase {
    private func snapshot(_ id: String = "fake", source: String = "test") -> AIUsageSnapshot {
        AIUsageSnapshot(
            providerID: id,
            meters: [
                AIUsageMeter(label: "Session", used: 100, limit: 200, unit: .tokens, resetsAt: nil)
            ],
            balance: Decimal(10),
            currency: "USD",
            source: source
        )
    }

    // MARK: Strategy chain

    func testChainReturnsFirstSuccessfulStrategy() async throws {
        let api = FakeStrategy(source: "api", outcome: .failure(.rateLimited("fake", retryAfter: 60)))
        let cli = FakeStrategy(source: "cli", outcome: .success(snapshot(source: "cli")))
        let provider = FakeProvider(id: "fake", strategies: [api, cli])

        let result = try await provider.fetch()

        XCTAssertEqual(result.source, "cli", "snapshot must be tagged with the winning strategy's source")
        XCTAssertEqual(api.calls, 1)
        XCTAssertEqual(cli.calls, 1)
    }

    func testChainCollectsAllPartialFailures() async {
        let first = FakeStrategy(source: "api", outcome: .failure(.timedOut("boom 1")))
        let second = FakeStrategy(source: "cli", outcome: .failure(.timedOut("boom 2")))
        let provider = FakeProvider(id: "fake", strategies: [first, second])

        do {
            _ = try await provider.fetch()
            XCTFail("expected the chain to fail")
        } catch let error as AIUsageError {
            guard case .chainFailed(let failures) = error else {
                return XCTFail("expected chainFailed, got \(error)")
            }
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(failures[0].contains("boom 1"))
            XCTAssertTrue(failures[1].contains("boom 2"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Cache / stale-while-revalidate

    func testFreshCacheServedWithoutRefetch() async throws {
        let strategy = FakeStrategy(source: "api", outcome: .success(snapshot()))
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 300)

        let first = try await service.usage(for: "fake")
        let second = try await service.usage(for: "fake")

        XCTAssertEqual(first.providerID, "fake")
        XCTAssertEqual(second, first)
        XCTAssertEqual(strategy.calls, 1, "fresh cache must not refetch")
    }

    func testStaleSnapshotServedWhileBackgroundRefreshRuns() async throws {
        let strategy = FakeStrategy(source: "api", outcome: .success(snapshot()))
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 0.05)

        let first = try await service.usage(for: "fake")
        XCTAssertEqual(strategy.calls, 1)

        try await Task.sleep(for: .seconds(0.1))
        let stale = try await service.usage(for: "fake")
        XCTAssertEqual(stale, first, "stale snapshot must be served while refreshing")
        XCTAssertGreaterThanOrEqual(stale.staleness, 0)
    }

    func testFailedRefreshDegradesToStaleSnapshot() async throws {
        let strategy = FakeStrategy(
            source: "api",
            outcome: .success(snapshot())
        )
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 0.05)

        let first = try await service.usage(for: "fake")

        // The provider now fails, but the stale snapshot must still be served.
        strategy.outcome = .failure(.timedOut("network down"))
        try await Task.sleep(for: .seconds(0.1))
        let degraded = try await service.usage(for: "fake")

        XCTAssertEqual(degraded, first, "network failure degrades to stale-with-timestamp, not an empty display")
    }

    // MARK: Rate-limit backoff

    func testRateLimitBackoffServesStaleWithoutRefetch() async throws {
        let strategy = FakeStrategy(source: "api", outcome: .success(snapshot()))
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 0.05)

        _ = try await service.usage(for: "fake")
        XCTAssertEqual(strategy.calls, 1)

        // Provider is now rate limited; the next refresh attempt hits 429.
        strategy.outcome = .failure(.rateLimited("fake", retryAfter: 3600))
        try await Task.sleep(for: .seconds(0.15))
        let stale = try await service.usage(for: "fake")
        XCTAssertEqual(stale.providerID, "fake", "rate-limited refresh still serves the stale snapshot")

        // Let the background refresh hit the 429 and record the backoff.
        try await Task.sleep(for: .seconds(0.2))
        let callsAfterRateLimit = strategy.calls
        XCTAssertGreaterThan(callsAfterRateLimit, 1, "the stale refresh must have attempted a refetch")

        _ = try await service.usage(for: "fake")
        XCTAssertEqual(
            strategy.calls, callsAfterRateLimit,
            "backoff must not refetch while the rate limit is active"
        )
    }

    func testRateLimitBackoffExpires() async throws {
        let strategy = FakeStrategy(source: "api", outcome: .success(snapshot()))
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 0.05)

        _ = try await service.usage(for: "fake")

        strategy.outcome = .failure(.rateLimited("fake", retryAfter: 0.1))
        try await Task.sleep(for: .seconds(0.1))
        _ = try await service.usage(for: "fake")
        let callsDuringBackoff = strategy.calls

        // After the backoff window, a refresh is attempted again.
        strategy.outcome = .success(snapshot())
        try await Task.sleep(for: .seconds(0.4))
        let afterExpiry = try await service.usage(for: "fake")
        XCTAssertGreaterThan(strategy.calls, callsDuringBackoff, "refresh must resume after the backoff expires")
        XCTAssertEqual(afterExpiry.providerID, "fake")
    }

    func testRateLimitBackoffWithoutCachedSnapshotThrowsUntilExpiry() async {
        let strategy = FakeStrategy(source: "api", outcome: .failure(.rateLimited("fake", retryAfter: 60)))
        let provider = FakeProvider(
            id: "fake",
            strategies: [strategy],
            directError: .rateLimited("fake", retryAfter: 60)
        )
        let service = AIUsageService(providers: [provider])

        do {
            _ = try await service.usage(for: "fake")
            XCTFail("expected the initial rate limit")
        } catch let error as AIUsageError {
            guard case .redacted(let message) = error else {
                return XCTFail("expected a redacted rate-limit error, got \(error)")
            }
            XCTAssertTrue(message.contains("rate limited"))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        do {
            _ = try await service.usage(for: "fake")
            XCTFail("expected the cached rate limit")
        } catch let error as AIUsageError {
            guard case .rateLimited = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(provider.calls, 1, "an active backoff must not refetch without a cached snapshot")
    }

    func testConcurrentRequestsShareOneFetch() async throws {
        let strategy = FakeStrategy(source: "api", outcome: .sleepThenSuccess(0.05, snapshot()))
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider])

        async let first = service.usage(for: "fake")
        async let second = service.usage(for: "fake")
        let (firstSnapshot, secondSnapshot) = try await (first, second)

        XCTAssertEqual(firstSnapshot, secondSnapshot)
        XCTAssertEqual(strategy.calls, 1, "concurrent callers must share the in-flight fetch")
    }

    // MARK: Timeout + concurrency

    func testHangingProviderTimesOut() async {
        let strategy = FakeStrategy(
            source: "api",
            outcome: .sleepThenSuccess(0.5, snapshot())
        )
        let provider = FakeProvider(id: "fake", strategies: [strategy])
        let service = AIUsageService(providers: [provider], refreshInterval: 300, providerTimeout: 0.05)

        do {
            _ = try await service.usage(for: "fake")
            XCTFail("expected a timeout")
        } catch let error as AIUsageError {
            XCTAssertTrue(error.description.lowercased().contains("timed out"), "unexpected: \(error)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHangingProviderDoesNotBlockOthers() async throws {
        let slow = FakeProvider(
            id: "slow",
            strategies: [FakeStrategy(source: "api", outcome: .sleepThenSuccess(0.5, snapshot("slow")))]
        )
        let fast = FakeProvider(
            id: "fast",
            strategies: [FakeStrategy(source: "api", outcome: .success(snapshot("fast")))]
        )
        let service = AIUsageService(providers: [slow, fast], refreshInterval: 300, providerTimeout: 0.05)

        let start = Date()
        let results = await service.usageAll()

        let slowResult = results.first { $0.providerID == "slow" }
        let fastResult = results.first { $0.providerID == "fast" }
        XCTAssertNotNil(slowResult?.error, "hanging provider must be isolated as an error")
        XCTAssertEqual(fastResult?.snapshot?.providerID, "fast", "fast provider must succeed")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4, "the hanging provider must not block the aggregate")
    }

    // MARK: Configuration + unknown providers

    func testUnconfiguredProviderErrorsWithoutFetching() async {
        let strategy = FakeStrategy(source: "api", outcome: .success(snapshot()))
        let provider = FakeProvider(id: "off", isConfigured: false, strategies: [strategy])
        let service = AIUsageService(providers: [provider])

        do {
            _ = try await service.usage(for: "off")
            XCTFail("expected notConfigured")
        } catch let error as AIUsageError {
            guard case .notConfigured = error else {
                return XCTFail("expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(strategy.calls, 0, "unconfigured providers must not touch credentials or the network")
    }

    func testUnknownProvider() async {
        let service = AIUsageService(providers: [])
        do {
            _ = try await service.usage(for: "nope")
            XCTFail("expected unknownProvider")
        } catch let error as AIUsageError {
            guard case .unknownProvider = error else {
                return XCTFail("expected unknownProvider, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Redaction

    func testTokenMaterialNeverLeavesTheService() async {
        // A provider that leaks a token-shaped string in its error message.
        let leaky = FakeStrategy(
            source: "api",
            outcome: .failure(.timedOut("auth failed for sk-abcdef1234567890abcdef with key=ghp_1234567890abcdefghijklmnop"))
        )
        let provider = FakeProvider(id: "leaky", strategies: [leaky])
        let service = AIUsageService(providers: [provider])

        let results = await service.usageAll()
        let error = results.first { $0.providerID == "leaky" }?.error ?? ""

        XCTAssertFalse(error.contains("sk-abcdef1234567890abcdef"), "token must not reach the caller")
        XCTAssertFalse(error.contains("ghp_1234567890abcdefghijklmnop"), "token must not reach the caller")
        XCTAssertTrue(error.contains(SecretRedactor.placeholder), "redaction must be visible, not silent truncation")
    }

    func testRedactorHandlesCommonShapes() {
        XCTAssertEqual(
            SecretRedactor.redact("key: sk-ABCDefgh12345678-xyz, header: Bearer abcdef1234567890"),
            "key: <redacted>, header: <redacted>"
        )
        XCTAssertEqual(
            SecretRedactor.redact("token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
            "<redacted>"
        )
        XCTAssertEqual(SecretRedactor.redact("no secrets here"), "no secrets here")
    }

    // MARK: Codable

    func testSnapshotCodableSnakeCase() throws {
        // Whole seconds so the iso8601 date round-trip is exact, and a non-nil
        // resetsAt so the snake_case key is actually emitted (synthesized
        // Codable omits nil optionals).
        let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AIUsageSnapshot(
            providerID: "fake",
            meters: [
                AIUsageMeter(label: "Session", used: 100, limit: 200, unit: .tokens, resetsAt: nil),
                AIUsageMeter(label: "Credits", used: Decimal(1.5), limit: Decimal(10), unit: .currency("USD"), resetsAt: resetDate)
            ],
            balance: Decimal(8.5),
            currency: "USD",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_001),
            source: "api"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"provider_id\""))
        XCTAssertTrue(json.contains("\"fetched_at\""))
        XCTAssertTrue(json.contains("\"resets_at\""))

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIUsageSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }
}

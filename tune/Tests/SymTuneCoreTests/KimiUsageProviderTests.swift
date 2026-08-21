import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class KimiUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesAPIUsageFixture() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-api-usages"), httpResponse(200))))
        let strategy = KimiAPIStrategy(
            apiKey: "kimi-test-key",
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "kimi")
        XCTAssertEqual(snapshot.source, "api")
        // Weekly subscription pool: 214 of 2048.
        let weekly = snapshot.meters.first { $0.label == "Weekly quota" }
        XCTAssertEqual(weekly?.used, Decimal(214))
        XCTAssertEqual(weekly?.limit, Decimal(2048))
        XCTAssertEqual(weekly?.unit, .requests)
        XCTAssertNotNil(weekly?.resetsAt)
        // 5h rate-limit window: 139 of 200.
        let window = snapshot.meters.first { $0.label == "5h window" }
        XCTAssertEqual(window?.used, Decimal(139))
        XCTAssertEqual(window?.limit, Decimal(200))
        XCTAssertEqual(window?.unit, .requests)
        XCTAssertNotNil(window?.resetsAt)
    }

    func testParsesWebUsageFixture() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-web-usages"), httpResponse(200))))
        let strategy = KimiWebStrategy(authToken: "kimi-test-web-token", network: network)

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "kimi")
        XCTAssertEqual(snapshot.source, "web")
        let weekly = snapshot.meters.first { $0.label == "Weekly quota" }
        XCTAssertEqual(weekly?.limit, Decimal(2048))
        XCTAssertTrue(snapshot.meters.contains { $0.label == "5h window" })
    }

    func testResetTimeParsesNanosecondFractionalISO8601() throws {
        let date = try XCTUnwrap(KimiUsageParsing.parseResetTime("2026-01-09T15:23:13.716839300Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1767972193.7168393, accuracy: 0.001)
    }

    func testResetTimeParsesPlainISO8601() throws {
        let date = try XCTUnwrap(KimiUsageParsing.parseResetTime("2026-01-09T15:23:13Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1767972193, accuracy: 0.001)
    }

    // MARK: API strategy wire format

    func testAPIStrategyUsesBearerAndDefaultHost() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-api-usages"), httpResponse(200))))
        let strategy = KimiAPIStrategy(
            apiKey: "kimi-test-key",
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer kimi-test-key")
        XCTAssertEqual(network.lastRequest?.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
        XCTAssertEqual(network.lastRequest?.httpMethod, "GET")
    }

    func testAPIStrategyHonorsBaseOverride() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-api-usages"), httpResponse(200))))
        let strategy = KimiAPIStrategy(
            apiKey: "kimi-test-key",
            baseURL: URL(string: "https://usage.test.local")!,
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.url?.absoluteString, "https://usage.test.local/coding/v1/usages")
    }

    // MARK: CLI credential path (read-only)

    func testCLIStrategySendsDeviceIdentityHeaders() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-api-usages"), httpResponse(200))))
        let strategy = KimiCLIStrategy(
            accessToken: "kimi-cli-token",
            identityHeaders: KimiCLIIdentityHeaders(deviceID: "device-1234", hostName: "test-host").all,
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
            network: network
        )

        _ = try await strategy.fetch()

        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer kimi-cli-token")
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "X-Msh-Device-Id"), "device-1234")
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "X-Msh-Device-Name"), "test-host")
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "X-Msh-Platform"), "macos")
    }

    func testCLICredentialStoreReadsTokenAndDeviceID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("credentials"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let credentials = """
        {"access_token":"kimi-cli-token-123","expires_at":"2026-12-31T00:00:00Z","token_type":"Bearer"}
        """
        try Data(credentials.utf8).write(to: dir.appendingPathComponent("credentials/kimi-code.json"))
        try Data("device-abc\n".utf8).write(to: dir.appendingPathComponent("device_id"))

        let store = KimiCLICredentialStore(home: dir.path)
        XCTAssertEqual(store.readAccessToken(), "kimi-cli-token-123")
        XCTAssertEqual(store.readDeviceID(), "device-abc")
    }

    func testCLICredentialStoreIsReadOnlyNeverCreatesFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KimiCLICredentialStore(home: dir.path)
        XCTAssertNil(store.readAccessToken())
        XCTAssertNil(store.readDeviceID())
        // Nothing may have been created by the read (no device_id, no credentials dir).
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path + "/device_id"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path + "/credentials"))
    }

    func testDefaultCLIHomePrefersCurrentLayout() throws {
        // When neither layout exists, the current (~/.kimi-code) path wins.
        let home = KimiUsageProvider.defaultCLIHome()
        XCTAssertTrue(home.hasSuffix("/.kimi-code"))
    }

    // MARK: Provider configuration

    func testProviderUnconfiguredWithoutAnyCredential() {
        let provider = KimiUsageProvider(
            apiKey: nil,
            cliHome: "/nonexistent/kimi-home-\(UUID().uuidString)",
            authToken: nil
        )
        XCTAssertFalse(provider.isConfigured)
        XCTAssertTrue(provider.strategies.isEmpty)
    }

    func testProviderConfiguredWithAPIKeyOnly() {
        let provider = KimiUsageProvider(
            apiKey: "kimi-test-key",
            cliHome: "/nonexistent/kimi-home-\(UUID().uuidString)",
            authToken: nil
        )
        XCTAssertTrue(provider.isConfigured)
        XCTAssertEqual(provider.strategies.count, 1)
        XCTAssertEqual(provider.strategies[0].source, "api")
    }

    func testProviderOrdersStrategiesAPIThenCLIThenWeb() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("credentials"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = """
        {"access_token":"kimi-cli-token-123","token_type":"Bearer"}
        """
        try Data(credentials.utf8).write(to: dir.appendingPathComponent("credentials/kimi-code.json"))

        let provider = KimiUsageProvider(
            apiKey: "kimi-test-key",
            cliHome: dir.path,
            authToken: "kimi-test-web-token"
        )
        XCTAssertEqual(provider.strategies.map(\.source), ["api", "cli", "web"])
    }

    func testCLIStrategyWorksWithoutDeviceID() async throws {
        let network = FakeNetwork(result: .success((try fixture("kimi-api-usages"), httpResponse(200))))
        let strategy = KimiCLIStrategy(
            accessToken: "kimi-cli-token",
            identityHeaders: KimiCLIIdentityHeaders(deviceID: nil, hostName: "test-host").all,
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "cli")
        XCTAssertNil(network.lastRequest?.value(forHTTPHeaderField: "X-Msh-Device-Id"))
    }

    // MARK: Errors never leak token material

    func testAuthErrorIsUnderstandableWithoutTokenMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = KimiAPIStrategy(
            apiKey: "kimi-super-secret-key",
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
            network: network
        )

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as KimiError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("credential"), message)
            XCTAssertFalse(message.contains("kimi-super-secret-key"), "token material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testAPIStrategyHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "12"])
        )))
        let strategy = KimiAPIStrategy(
            apiKey: "kimi-test-key",
            baseURL: KimiUsageProvider.defaultAPIBaseURL,
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
            XCTAssertEqual(id, "kimi")
            XCTAssertEqual(retryAfter, 12)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testWebStrategyHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = KimiWebStrategy(authToken: "kimi-test-web-token", network: network)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "kimi")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

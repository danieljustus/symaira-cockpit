import XCTest
@testable import SymTuneCore

// FakeNetwork is shared with OpenRouterUsageProviderTests (same test target).

// MARK: - Tests

final class NousPortalUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://portal.nousresearch.com/api/oauth/account")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Parsing fixtures (no network)

    func testParsesAccountResponse() async throws {
        let network = FakeNetwork(result: .success((try fixture("nous-account"), httpResponse(200))))
        let strategy = NousPortalAPIStrategy(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!,
            network: network
        )

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "nous")
        XCTAssertEqual(snapshot.source, "api")
        XCTAssertEqual(snapshot.balance, Decimal(57.5))
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Subscription credits" && $0.used == Decimal(42.5) })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Purchased credits" && $0.used == Decimal(15) })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Plan credits remaining" && $0.limit == Decimal(100) })
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Rollover credits" })
    }

    func testProviderUnconfiguredWithoutToken() {
        let provider = NousPortalUsageProvider(
            accessToken: "",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!
        )
        XCTAssertFalse(provider.isConfigured)
    }

    func testProviderConfiguredWithToken() {
        let provider = NousPortalUsageProvider(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!
        )
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: Auth store (strictly read-only)

    func testAuthStoreReadsInvokeJWTFromFixtures() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A JWT with exp far in the future.
        let future = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let payload = "{\"exp\":\(future)}".data(using: .utf8)!
            .base64URLEncodedString()
        let token = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let store = """
        {
          "version": 1,
          "providers": [
            {"id": "nous", "invoke_jwt": "\(token)", "client_id": "hermes-cli"}
          ]
        }
        """
        try store.write(to: tmp.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        // The reader must see the invoke JWT without touching the file.
        let before = try Data(contentsOf: tmp.appendingPathComponent("auth.json"))
        let reader = TestAuthStore(path: tmp.appendingPathComponent("auth.json"))
        let read = reader.readAccessToken()
        let after = try Data(contentsOf: tmp.appendingPathComponent("auth.json"))

        XCTAssertEqual(read, token)
        XCTAssertEqual(before, after, "auth.json must stay byte-identical after a read")
    }

    func testAuthStoreTreatsExpiredJWTAsUnavailable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A JWT with exp in the past.
        let past = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let payload = "{\"exp\":\(past)}".data(using: .utf8)!
            .base64URLEncodedString()
        let token = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let store = """
        {
          "version": 1,
          "providers": [
            {"id": "nous", "invoke_jwt": "\(token)", "client_id": "hermes-cli"}
          ]
        }
        """
        try store.write(to: tmp.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let reader = TestAuthStore(path: tmp.appendingPathComponent("auth.json"))
        XCTAssertNil(reader.readAccessToken(), "expired token must surface as re-auth needed, never refreshed")
    }

    func testAuthStoreIgnoresOtherProviders() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = """
        {
          "version": 1,
          "providers": [
            {"id": "opencode", "access_token": "sekrit"}
          ]
        }
        """
        try store.write(to: tmp.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let reader = TestAuthStore(path: tmp.appendingPathComponent("auth.json"))
        XCTAssertNil(reader.readAccessToken(), "other providers' tokens must not be used for nous")
    }

    // MARK: Errors never leak token material

    func testAuthErrorSurfacesReAuthHintWithoutTokenMaterial() async {
        let network = FakeNetwork(result: .success(("nope".data(using: .utf8)!, httpResponse(401))))
        let strategy = NousPortalAPIStrategy(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWNyZXQifQ.sig-secret-material",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!,
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
            XCTAssertEqual(id, "nous")
            XCTAssertFalse(error.localizedDescription.contains("sig-secret"), "token material must never leak")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAuthorizationHeaderUsesBearerToken() async throws {
        let network = FakeNetwork(result: .success((try fixture("nous-account"), httpResponse(200))))
        let strategy = NousPortalAPIStrategy(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!,
            network: network
        )

        _ = try await strategy.fetch()

        let auth = network.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig")
        XCTAssertEqual(network.lastRequest?.url?.path, "/api/oauth/account")
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let network = FakeNetwork(result: .success((
            Data(),
            httpResponse(429, headers: ["Retry-After": "20"])
        )))
        let strategy = NousPortalAPIStrategy(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!,
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
            XCTAssertEqual(id, "nous")
            XCTAssertEqual(retryAfter, 20)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testHTTP429WithoutRetryAfterHeaderYieldsNilRetryAfter() async throws {
        let network = FakeNetwork(result: .success((Data(), httpResponse(429))))
        let strategy = NousPortalAPIStrategy(
            accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig",
            portalBaseURL: URL(string: "https://portal.nousresearch.com")!,
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
            XCTAssertEqual(id, "nous")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

// MARK: - Test seam for the auth-store reader

private struct TestAuthStore: NousAuthStoreReading {
    let path: URL
    func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]]
        else { return nil }
        for provider in providers {
            guard (provider["id"] as? String) == "nous" else { continue }
            let token = (provider["invoke_jwt"] as? String) ?? (provider["access_token"] as? String)
            guard let token, !token.isEmpty else { return nil }
            if token.contains("."), NousJWT.expiry(of: token) == nil {
                return nil
            }
            return token
        }
        return nil
    }
}

// MARK: - Base64URL helper (test fixture building)

private extension Data {
    /// Base64URL (no padding, URL-safe alphabet) — the JWT payload shape.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

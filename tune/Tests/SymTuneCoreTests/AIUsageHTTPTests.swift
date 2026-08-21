import XCTest
@testable import SymTuneCore

// MARK: - Stub network

/// Scripted network seam for the shared HTTP layer tests.
private final class StubNetwork: NetworkServiceProtocol, @unchecked Sendable {
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

/// Minimal decodable used to exercise snake_case key decoding.
///
/// Note: the field names must be ones that `convertFromSnakeCase` maps
/// unambiguously — a run of consecutive capitals such as `totalCostUSD`
/// would be rewritten by Foundation as `total_cost_u_s_d`, not the
/// `total_cost_usd` in a real payload. Real provider models that decode
/// acronym keys do so via explicit `CodingKeys` (see ClaudeUsageProvider),
/// not via the strategy.
private struct SamplePayload: Decodable, Equatable {
    let totalCost: Double?
    let usageResetDate: Date?

    enum CodingKeys: String, CodingKey {
        case totalCost
        case usageResetDate
    }
}

// MARK: - Tests

final class AIUsageHTTPTests: XCTestCase {
    private func response(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.test/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func request() -> URLRequest {
        var r = URLRequest(url: URL(string: "https://example.test/usage")!)
        r.httpMethod = "GET"
        return r
    }

    // MARK: Status mapping

    func test2xxDecodesSnakeCaseJSON() async throws {
        let body = #"{"total_cost": 12.5, "usage_reset_date": "2026-01-01T00:00:00Z"}"#
        let network = StubNetwork(result: .success((body.data(using: .utf8)!, response(200))))
        let payload: SamplePayload = try await AIUsageHTTP.json(
            request(), as: SamplePayload.self, providerID: "sample", network: network
        )
        XCTAssertEqual(payload.totalCost, 12.5)
        XCTAssertNotNil(payload.usageResetDate)
    }

    func test429MapsToRateLimitedWithRetryAfter() async throws {
        let network = StubNetwork(result: .success((
            "rate limited".data(using: .utf8)!, response(429, headers: ["Retry-After": "37"])
        )))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "sample")
            XCTAssertEqual(retryAfter, 37)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test429WithoutRetryAfterYieldsNilRetryAfter() async throws {
        let network = StubNetwork(result: .success((Data(), response(429))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "sample")
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test401MapsToNotConfigured() async throws {
        let network = StubNetwork(result: .success(("denied".data(using: .utf8)!, response(401))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .notConfigured(let id) = error else {
                XCTFail("expected .notConfigured, got \(error)")
                return
            }
            XCTAssertEqual(id, "sample")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test403MapsToNotConfigured() async throws {
        let network = StubNetwork(result: .success(("forbidden".data(using: .utf8)!, response(403))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .notConfigured(let id) = error else {
                XCTFail("expected .notConfigured, got \(error)")
                return
            }
            XCTAssertEqual(id, "sample")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testOtherStatusMapsToHTTPStatus() async throws {
        let network = StubNetwork(result: .success(("boom".data(using: .utf8)!, response(500))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageHTTPError {
            guard case .httpStatus(let code) = error else {
                XCTFail("expected .httpStatus, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNonHTTPResponseMapsToInvalidResponse() async throws {
        let nonHTTP = URLResponse(url: URL(string: "https://example.test")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        let network = StubNetwork(result: .success((Data(), nonHTTP)))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageHTTPError {
            guard case .invalidResponse = error else {
                XCTFail("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNetworkErrorMapsToNetwork() async throws {
        struct Boom: Error {}
        let network = StubNetwork(result: .failure(Boom()))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
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

    // MARK: Body never reaches an error

    func testErrorNeverEmbedsResponseBody() async throws {
        // A gateway error page can echo the request headers back (including
        // a provider's API key), so the body must never surface in an error.
        let body = "<html>Authorization: Bearer sk-SUPERSECRET</html>"
        let network = StubNetwork(result: .success((body.data(using: .utf8)!, response(500))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("sk-SUPERSECRET"), "response body must never surface in an error: \(message)")
            XCTAssertFalse(message.contains("<html>"), "response body must never surface in an error: \(message)")
        }
    }

    // MARK: Header default

    func testAttachesAcceptHeaderWhenAbsent() async throws {
        let body = #"{"total_cost_usd": 1.0}"#
        let network = StubNetwork(result: .success((body.data(using: .utf8)!, response(200))))
        _ = try await AIUsageHTTP.json(
            request(), as: SamplePayload.self, providerID: "sample", network: network
        )
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testKeepsExistingAcceptHeader() async throws {
        let body = #"{"total_cost_usd": 1.0}"#
        var r = request()
        r.setValue("text/plain", forHTTPHeaderField: "Accept")
        let network = StubNetwork(result: .success((body.data(using: .utf8)!, response(200))))
        _ = try await AIUsageHTTP.json(
            r, as: SamplePayload.self, providerID: "sample", network: network
        )
        XCTAssertEqual(network.lastRequest?.value(forHTTPHeaderField: "Accept"), "text/plain")
    }

    // MARK: Unparseable body

    func testUnparseableBodyMapsToUnparseable() async throws {
        let network = StubNetwork(result: .success(("not json".data(using: .utf8)!, response(200))))
        do {
            _ = try await AIUsageHTTP.json(
                request(), as: SamplePayload.self, providerID: "sample", network: network
            )
            XCTFail("expected an error")
        } catch let error as AIUsageHTTPError {
            guard case .unparseable = error else {
                XCTFail("expected .unparseable, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

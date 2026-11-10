import Foundation
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageAPIHostTests: XCTestCase {
    @MainActor
    func testOptInHostPublishesMemoryAndStopsOnDisable() async throws {
        let host = AIUsageAPIHost(port: 0)
        let rows: [AIUsageService.ProviderResult] = [.init(providerID: "codex", snapshot: nil, error: nil)]
        host.update(enabled: false, rows: rows)
        XCTAssertEqual(host.status, "Local API is off")
        host.update(enabled: true, rows: rows)
        defer { host.stop() }
        let deadline = Date().addingTimeInterval(5)
        while host.status == "Starting local API…", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(host.status.hasPrefix("Local API: 127.0.0.1:"), host.status)
        let address = host.status.replacingOccurrences(of: "Local API: ", with: "http://")
        let url = try XCTUnwrap(URL(string: address + "/v1/limits/codex"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["providers"] as? [String: Any])?.count, 0)
        host.update(enabled: false, rows: rows)
        XCTAssertEqual(host.status, "Local API is off")
        do {
            _ = try await session.data(for: request)
            XCTFail("Disabled API still accepts requests")
        } catch { /* Connection refusal is the expected disabled state. */ }
    }

    @MainActor
    func testDisableDuringStartDoesNotReopenListener() async throws {
        let host = AIUsageAPIHost(port: 0)
        host.update(enabled: true, rows: [])
        host.update(enabled: false, rows: [])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.status, "Local API is off")
    }
}

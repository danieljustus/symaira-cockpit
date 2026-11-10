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
        // Shutdown runs off the main actor, so refusal is eventual, not immediate.
        let refusalDeadline = Date().addingTimeInterval(5)
        var refused = false
        while !refused, Date() < refusalDeadline {
            do {
                _ = try await session.data(for: request)
                try await Task.sleep(for: .milliseconds(20))
            } catch is CancellationError {
                break
            } catch { refused = true }
        }
        XCTAssertTrue(refused, "Disabled API still accepts requests")
    }

    @MainActor
    func testStartFailureNamesTheActualPort() async throws {
        let occupier = AIUsageLocalServer(port: 0) { [] }
        let taken = try occupier.start()
        defer { occupier.stop() }
        let host = AIUsageAPIHost(port: taken)
        host.update(enabled: true, rows: [])
        defer { host.stop() }
        let deadline = Date().addingTimeInterval(5)
        while host.status == "Starting local API…", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(host.status.contains("port \(taken)."), host.status)
        XCTAssertFalse(host.status.contains("6737") && taken != 6737, host.status)
    }

    @MainActor
    func testDisableThenEnableRebindsWithoutRacingTheStoppedInstance() async throws {
        let host = AIUsageAPIHost(port: 0)
        defer { host.stop() }
        host.update(enabled: true, rows: [])
        host.update(enabled: false, rows: [])
        host.update(enabled: true, rows: [])
        let deadline = Date().addingTimeInterval(5)
        while host.status == "Starting local API…", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(host.status.hasPrefix("Local API: 127.0.0.1:"), host.status)
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

import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageBoundaryTests: XCTestCase {
    func testDecimalParsingRejectsPartialAndNonFiniteValues() throws {
        for invalid in ["12garbage", "NaN", "Infinity", "1.2.3", "12\n", "", "1e9999"] {
            let snapshot = try decodeSnapshot(used: invalid)
            XCTAssertThrowsError(try snapshot.aiUsageSnapshot(), invalid)
        }
        for valid in ["0", "12.50", "-1", "1e2"] {
            XCTAssertNoThrow(try decodeSnapshot(used: valid).aiUsageSnapshot())
        }
    }

    func testLiveSnapshotRedactsTextBeforeCLIOrGUIOutput() throws {
        let secret = "sk-" + String(repeating: "x", count: 48)
        let snapshot = try decodeSnapshot(used: "12", label: "Bearer " + secret).aiUsageSnapshot()
        XCTAssertFalse(snapshot.meters[0].label.contains(secret))
    }

    func testUnsupportedSelectiveClientNeverFallsBackToAllProviders() async {
        let client = AllOnlyClient()
        let service = AIUsageService(client: client)
        let results = await service.usageAll(providerIDs: ["codex"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.error, SymBrainUsageError.providerSelectionUnsupported.errorDescription)
        XCTAssertFalse(client.called)
    }

    private func decodeSnapshot(used: String, label: String = "Session") throws -> SymBrainUsageSnapshot {
        let object: [String: Any] = [
            "provider_id": "codex", "fetched_at": "2026-10-28T08:00:00Z", "source": "oauth",
            "meters": [["label": label, "used": used, "limit": "100", "unit": "percent"]]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SymBrainUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private final class AllOnlyClient: SymBrainUsageClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var didCall = false
    var called: Bool { lock.withLock { didCall } }
    func fetchReport() throws -> SymBrainUsageReport {
        lock.withLock { didCall = true }
        throw SymBrainUsageError.binaryUnavailable
    }
}

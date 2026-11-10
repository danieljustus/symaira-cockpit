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

    func testOlderBrainRejectingProvidersFlagMapsToUpdateMessageForAnyExitStatus() throws {
        for (status, stderr) in [(2, ""), (1, "Error: unknown flag: --providers\n"),
                                 (64, "unrecognized option '--providers'"), (1, "flag provided but not defined: -providers")] {
            let runner = FailingBrainRunner(status: Int32(status), stderr: stderr)
            let client = SymBrainUsageClient(runner: runner, environment: [:], credentialReference: { _ in nil })
            XCTAssertThrowsError(try client.fetchReport(providerIDs: ["codex"]), "status \(status)") { error in
                XCTAssertEqual(error as? SymBrainUsageError, .providerSelectionUnsupported)
            }
        }
        // An unrelated failure stays an honest generic failure, not an "update" hint.
        let broken = SymBrainUsageClient(runner: FailingBrainRunner(status: 1, stderr: "network down"),
                                         environment: [:], credentialReference: { _ in nil })
        XCTAssertThrowsError(try broken.fetchReport(providerIDs: ["codex"])) { error in
            XCTAssertEqual(error as? SymBrainUsageError, .commandFailed(1))
        }
        // The unselected path never maps to the selection error.
        XCTAssertThrowsError(try broken.fetchReport()) { error in
            XCTAssertEqual(error as? SymBrainUsageError, .commandFailed(1))
        }
    }

    func testUpdateMessageNamesTheRequiredContractAndStaysSecretFree() {
        let message = SymBrainUsageError.providerSelectionUnsupported.errorDescription ?? ""
        XCTAssertTrue(message.contains("update symbrain"), message)
        XCTAssertTrue(message.contains("--providers"), message)
        XCTAssertTrue(message.contains("SYMBRAIN_USAGE_*_HISTORY"), message)
    }

    func testProviderMissingFromAnOlderBrainReportNamesTheCause() async {
        let service = AIUsageService(providers: [SymBrainUsageProvider(id: "zai", displayName: "Z.ai")],
                                     client: EmptyReportClient())
        let result = await service.usageAll(providerIDs: ["zai"])
        XCTAssertTrue(result.first?.error?.hasPrefix("AI usage unavailable.") == true)
        XCTAssertTrue(result.first?.error?.contains("symbrain did not report this provider") == true)
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

private struct FailingBrainRunner: SymBrainCommandRunner {
    let status: Int32
    let stderr: String
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        SymBrainCommandResult(standardOutput: Data(), standardError: Data(stderr.utf8), terminationStatus: status)
    }
}

private struct EmptyReportClient: SymBrainUsageClientProtocol {
    func fetchReport() throws -> SymBrainUsageReport { SymBrainUsageReport(schemaVersion: 1, providers: []) }
    func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport {
        SymBrainUsageReport(schemaVersion: 1, providers: [])
    }
}

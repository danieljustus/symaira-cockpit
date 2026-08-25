import Foundation
import XCTest
@testable import SymTuneCore

private struct RecordingRunner: SymBrainCommandRunner {
    let output: SymBrainCommandResult
    let recorder: Recorder

    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        recorder.arguments = arguments
        recorder.environment = environment
        return output
    }
}

private final class Recorder: @unchecked Sendable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
}

private struct MissingRunner: SymBrainCommandRunner {
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        throw SymBrainUsageError.binaryUnavailable
    }
}

private struct FailingRunner: SymBrainCommandRunner {
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        SymBrainCommandResult(
            standardOutput: Data(),
            standardError: Data("provider token must not escape".utf8),
            terminationStatus: 17
        )
    }
}

final class SymBrainUsageClientTests: XCTestCase {
    private let reportJSON = #"""
    {
      "schema_version": 1,
      "providers": [
        {
          "id": "openrouter",
          "display_name": "OpenRouter",
          "configured": true,
          "auth_status": {"status": "available", "detail": "via Keychain", "source": "keyring"},
          "snapshot": {
            "provider_id": "openrouter",
            "meters": [
              {"label": "this month", "used": "12.50", "limit": "100", "unit": "USD", "resets_at": "2026-09-01T00:00:00Z"}
            ],
            "balance": "7.25",
            "currency": "USD",
            "fetched_at": "2026-08-25T12:00:00Z",
            "source": "api"
          }
        },
        {
          "id": "claude",
          "display_name": "Claude",
          "configured": false,
          "auth_status": {"status": "missing", "detail": "not signed in"}
        }
      ]
    }
    """#

    func testDecodesPublishedSymbrainJSONAndNormalizesSnapshot() throws {
        let client = SymBrainUsageClient(
            runner: RecordingRunner(
                output: SymBrainCommandResult(
                    standardOutput: Data(reportJSON.utf8),
                    standardError: Data(),
                    terminationStatus: 0
                ),
                recorder: Recorder()
            ),
            environment: ["PATH": "/usr/bin"]
        )

        let report = try client.fetchReport()
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.providers.count, 2)
        let openrouter = try XCTUnwrap(report.providers.first { $0.id == "openrouter" })
        let snapshot = try XCTUnwrap(openrouter.snapshot?.aiUsageSnapshot())
        XCTAssertEqual(snapshot.providerID, "openrouter")
        XCTAssertEqual(snapshot.source, "api")
        XCTAssertEqual(snapshot.balance, Decimal(string: "7.25"))
        XCTAssertEqual(snapshot.meters.first?.unit, .currency("USD"))
        XCTAssertEqual(snapshot.meters.first?.used, Decimal(string: "12.50"))
    }

    func testInvokesExactPublishedCommandAndBridgesKeychainValuesToEnvironment() throws {
        let recorder = Recorder()
        let client = SymBrainUsageClient(
            runner: RecordingRunner(
                output: SymBrainCommandResult(
                    standardOutput: Data(reportJSON.utf8),
                    standardError: Data(),
                    terminationStatus: 0
                ),
                recorder: recorder
            ),
            environment: ["PATH": "/usr/bin"],
            keychainReader: { service, account in
                XCTAssertEqual(service, "com.symaira.symtune")
                return account == "openrouter-api-key" ? "symvault://vault/openrouter" : nil
            }
        )

        _ = try client.fetchReport()
        XCTAssertEqual(recorder.arguments, ["usage", "--output", "json"])
        XCTAssertEqual(recorder.environment["OPENROUTER_API_KEY"], "symvault://vault/openrouter")
    }

    func testMissingBinaryIsAnExplicitRuntimeFailure() {
        let client = SymBrainUsageClient(runner: MissingRunner(), environment: [:], keychainReader: { _, _ in nil })
        XCTAssertThrowsError(try client.fetchReport()) { error in
            XCTAssertEqual(error as? SymBrainUsageError, .binaryUnavailable)
        }
    }

    func testNonZeroExitIsAnExplicitRuntimeFailureWithoutSurfacingStderr() {
        let client = SymBrainUsageClient(runner: FailingRunner(), environment: [:], keychainReader: { _, _ in nil })
        XCTAssertThrowsError(try client.fetchReport()) { error in
            XCTAssertEqual(error as? SymBrainUsageError, .commandFailed(17))
            XCTAssertFalse(String(describing: error).contains("provider token"))
        }
    }

    func testServicePreservesCLIAndMCPResultShapeAndUpdatesConfiguredStatus() async throws {
        let client = SymBrainUsageClient(
            runner: RecordingRunner(
                output: SymBrainCommandResult(
                    standardOutput: Data(reportJSON.utf8),
                    standardError: Data(),
                    terminationStatus: 0
                ),
                recorder: Recorder()
            ),
            environment: ["PATH": "/usr/bin"],
            keychainReader: { _, _ in nil }
        )
        let openrouter = try XCTUnwrap(SymBrainUsageProvider.catalog().first { $0.id == "openrouter" })
        let service = AIUsageService(providers: [openrouter], client: client)

        let results = await service.usageAll()
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.providerID, "openrouter")
        XCTAssertNotNil(result.snapshot)
        XCTAssertNil(result.error)
        XCTAssertTrue(openrouter.isConfigured)
        XCTAssertEqual(openrouter.authState.status, .available)
        XCTAssertEqual(service.credentialSources().first?.source, "keyring")
    }

    func testMissingBinaryBecomesUnavailableRowsInsteadOfAThrownUIError() async throws {
        let service = AIUsageService(client: SymBrainUsageClient(
            runner: MissingRunner(), environment: [:], keychainReader: { _, _ in nil }
        ))

        let results = await service.usageAll()
        XCTAssertEqual(results.count, SymBrainUsageProvider.catalog().count)
        XCTAssertTrue(results.allSatisfy { $0.snapshot == nil && $0.error == "AI usage unavailable." })
    }
}

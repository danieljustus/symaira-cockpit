import Foundation
import XCTest
@testable import SymTuneCore

private final class RecordingSymVaultRunner: SymVaultCommandRunner, @unchecked Sendable {
    var calls: [(arguments: [String], standardInput: Data?)] = []
    var status: Int32 = 0

    func run(arguments: [String], standardInput: Data?) throws -> SymVaultCommandResult {
        calls.append((arguments, standardInput))
        return SymVaultCommandResult(standardOutput: Data(), standardError: Data(), terminationStatus: status)
    }
}

private final class DeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deletions: [(String, String)] = []

    func record(service: String, account: String) {
        lock.withLock {
            deletions.append((service, account))
        }
    }

    var values: [(String, String)] {
        lock.withLock { deletions }
    }
}

final class SymVaultCredentialStoreTests: XCTestCase {
    func testReferenceUsesSymVaultWithoutReadingASecret() {
        XCTAssertEqual(SymVaultCredentialStore.reference(for: "openrouter"), "symvault://symtune/openrouter")
    }

    func testSaveUsesStdinAndNeverPlacesCredentialInArguments() throws {
        let runner = RecordingSymVaultRunner()
        let value = "test-value-\(UUID().uuidString)"
        let store = SymVaultCredentialStore(runner: runner)

        try store.save(value, for: "openrouter")

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(
            runner.calls[0].arguments,
            ["--quiet", "--no-pipe-warning", "set", "symtune/openrouter.password", "--stdin-value", "--force"]
        )
        XCTAssertEqual(String(data: runner.calls[0].standardInput ?? Data(), encoding: .utf8), value + "\n")
        XCTAssertFalse(runner.calls[0].arguments.contains(value))
    }

    func testSaveReportsSymVaultFailureWithoutSurfacingCommandOutput() {
        let runner = RecordingSymVaultRunner()
        runner.status = 17
        let store = SymVaultCredentialStore(runner: runner)

        XCTAssertThrowsError(try store.save("test-value", for: "kimi")) { error in
            XCTAssertEqual(error as? SymVaultCredentialError, .commandFailed(17))
            XCTAssertFalse(String(describing: error).contains("test-value"))
        }
    }

    func testMigrationDeletesLegacyItemOnlyAfterSuccessfulVaultWrite() throws {
        let runner = RecordingSymVaultRunner()
        let deleted = DeletionRecorder()
        let value = "legacy-value-\(UUID().uuidString)"
        let store = SymVaultCredentialStore(
            runner: runner,
            keychainReader: { service, account in
                XCTAssertEqual(service, SymVaultCredentialStore.legacyKeychainService)
                XCTAssertEqual(account, "moonshot-api-key")
                return value
            },
            keychainDeleter: { service, account in
                deleted.record(service: service, account: account)
                return true
            }
        )

        XCTAssertTrue(try store.migrateLegacyCredential(for: "moonshot"))
        XCTAssertEqual(deleted.values.count, 1)
        XCTAssertEqual(deleted.values[0].0, SymVaultCredentialStore.legacyKeychainService)
        XCTAssertEqual(deleted.values[0].1, "moonshot-api-key")
        XCTAssertEqual(
            runner.calls[0].arguments,
            ["--quiet", "--no-pipe-warning", "set", "symtune/moonshot.password", "--stdin-value", "--force"]
        )
        XCTAssertFalse(runner.calls[0].arguments.contains(value))
    }

    func testMigrationLeavesLegacyItemWhenVaultWriteFails() {
        let runner = RecordingSymVaultRunner()
        runner.status = 1
        let deleted = DeletionRecorder()
        let store = SymVaultCredentialStore(
            runner: runner,
            keychainReader: { _, _ in "legacy-value" },
            keychainDeleter: { service, account in
                deleted.record(service: service, account: account)
                return true
            }
        )

        XCTAssertThrowsError(try store.migrateLegacyCredential(for: "kimi"))
        XCTAssertTrue(deleted.values.isEmpty)
    }
}

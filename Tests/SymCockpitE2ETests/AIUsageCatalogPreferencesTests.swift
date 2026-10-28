import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageCatalogPreferencesTests: XCTestCase {
    @MainActor
    func testOptInAndLocalAuthSaveClearCustomPathSemantics() throws {
        let suite = "AIUsageCatalogPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        let runner = CatalogVaultRunner()
        let store = SymVaultCredentialStore(runner: runner,
            keychainReader: { _, _ in XCTFail("No Keychain access"); return nil },
            keychainDeleter: { _, _ in XCTFail("No Keychain access"); return false })
        XCTAssertTrue(preferences.enabledProviders.isEmpty)
        XCTAssertEqual(runner.calls.count, 0)
        for id in ["zai", "devin", "grok", "ollama", "opencode"] {
            XCTAssertFalse(preferences.isEnabled(id))
            preferences.setEnabled(id, true)
            XCTAssertTrue(AIUsagePreferences(defaults: defaults).isEnabled(id))
            preferences.setEnabled(id, false)
        }
        for id in ["devin", "grok", "opencode"] {
            XCTAssertNil(preferences.entryPaths.reference(for: id))
            runner.status = 1
            XCTAssertThrowsError(try preferences.saveCredential("fixture-value", for: id, store: store))
            XCTAssertNil(preferences.entryPaths.reference(for: id))
            runner.status = 0
            try preferences.saveCredential(" fixture-value ", for: id, store: store)
            XCTAssertEqual(runner.calls.last, ["--quiet", "--no-pipe-warning", "set", "symtune/\(id).password", "--stdin-value", "--force"])
            XCTAssertEqual(runner.input, Data("fixture-value\n".utf8))
            XCTAssertEqual(preferences.entryPaths.reference(for: id), "symvault://symtune/" + id)
            XCTAssertEqual(AIUsagePreferences(defaults: defaults).entryPaths.reference(for: id), "symvault://symtune/" + id)
            XCTAssertFalse(preferences.isEnabled(id), "Credential save must not grant provider consent")
            runner.status = 1
            XCTAssertFalse(preferences.deleteCredential(for: id, store: store))
            XCTAssertNotNil(preferences.entryPaths.reference(for: id))
            runner.status = 0
            XCTAssertTrue(preferences.deleteCredential(for: id, store: store))
            XCTAssertEqual(runner.calls.last, ["--quiet", "delete", "symtune/" + id, "--yes"])
            XCTAssertNil(preferences.entryPaths.reference(for: id))
            let callsBeforePathChange = runner.calls.count
            XCTAssertTrue(preferences.setVaultEntryPath("symvault://existing/work", for: id))
            XCTAssertEqual(preferences.entryPaths.reference(for: id), "symvault://existing/work")
            XCTAssertFalse(preferences.setVaultEntryPath("bad path", for: id))
            XCTAssertEqual(preferences.entryPaths.reference(for: id), "symvault://existing/work")
            XCTAssertTrue(preferences.setVaultEntryPath("", for: id))
            XCTAssertNil(preferences.entryPaths.reference(for: id))
            XCTAssertEqual(runner.calls.count, callsBeforePathChange, "Selecting/resetting paths must not touch the vault")
        }
    }
}

private final class CatalogVaultRunner: SymVaultCommandRunner, @unchecked Sendable {
    var calls: [[String]] = []
    var input: Data?
    var status: Int32 = 0
    func run(arguments: [String], standardInput: Data?) throws -> SymVaultCommandResult {
        calls.append(arguments)
        input = standardInput
        return SymVaultCommandResult(standardOutput: Data(), standardError: Data(), terminationStatus: status)
    }
}

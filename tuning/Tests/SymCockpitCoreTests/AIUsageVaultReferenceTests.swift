import Foundation
import XCTest
@testable import SymCockpitCore

/// Issue #376: usage resolves the user's existing SymVault entries instead of a
/// fixed `symtune/<provider>` path, and says so when an entry is missing.
private struct EnvironmentCapturingRunner: SymBrainCommandRunner {
    let recorder: EnvironmentRecorder

    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        recorder.environment = environment
        let report = #"{"schema_version": 1, "providers": []}"#
        return SymBrainCommandResult(standardOutput: Data(report.utf8), standardError: Data(), terminationStatus: 0)
    }
}

private final class EnvironmentRecorder: @unchecked Sendable {
    var environment: [String: String] = [:]
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() { lock.withLock { calls += 1 } }
    var value: Int { lock.withLock { calls } }
}

final class AIUsageVaultReferenceTests: XCTestCase {
    private func childEnvironment(
        environment: [String: String] = ["PATH": "/usr/bin"],
        reference: @escaping @Sendable (String) -> String?
    ) throws -> [String: String] {
        let recorder = EnvironmentRecorder()
        let client = SymBrainUsageClient(
            runner: EnvironmentCapturingRunner(recorder: recorder),
            environment: environment,
            credentialReference: reference
        )
        _ = try client.fetchReport()
        return recorder.environment
    }

    // MARK: Child environment mapping

    func testCustomEntryPathBecomesTheExactSymVaultReferenceInTheEnvironment() throws {
        let paths = SymVaultEntryPaths(["openrouter": "openrouter/work", "kimi": "kimi-coding/main"])
        let environment = try childEnvironment { paths.reference(for: $0) }

        XCTAssertEqual(environment["OPENROUTER_API_KEY"], "symvault://openrouter/work")
        XCTAssertEqual(environment["KIMI_CODE_API_KEY"], "symvault://kimi-coding/main")
    }

    func testProvidersWithoutACustomPathKeepTheDefaultSymtuneEntry() throws {
        let paths = SymVaultEntryPaths(["openrouter": "openrouter/work"])
        let environment = try childEnvironment { paths.reference(for: $0) }

        XCTAssertEqual(environment["MOONSHOT_API_KEY"], "symvault://symtune/moonshot")
        XCTAssertEqual(environment["MOONSHOT_API_KEY"], SymVaultCredentialStore.reference(for: "moonshot"))
    }

    func testNoOverridesMatchesTheOriginalDefaultReferences() throws {
        let environment = try childEnvironment { SymVaultEntryPaths().reference(for: $0) }

        XCTAssertEqual(environment["OPENROUTER_API_KEY"], "symvault://symtune/openrouter")
        XCTAssertEqual(environment["MOONSHOT_API_KEY"], "symvault://symtune/moonshot")
        XCTAssertEqual(environment["KIMI_CODE_API_KEY"], "symvault://symtune/kimi")
    }

    func testAnExistingEnvironmentValueIsNeverOverwrittenByTheChosenEntry() throws {
        let paths = SymVaultEntryPaths(["openrouter": "openrouter/work"])
        let environment = try childEnvironment(
            environment: ["PATH": "/usr/bin", "OPENROUTER_API_KEY": "already-set-by-the-user"]
        ) { paths.reference(for: $0) }

        XCTAssertEqual(environment["OPENROUTER_API_KEY"], "already-set-by-the-user")
        XCTAssertEqual(environment["KIMI_CODE_API_KEY"], "symvault://symtune/kimi")
    }

    func testReferenceIsResolvedAtFetchTimeNotAtConstruction() throws {
        let counter = CallCounter()
        let client = SymBrainUsageClient(
            runner: EnvironmentCapturingRunner(recorder: EnvironmentRecorder()),
            environment: [:],
            credentialReference: { _ in
                counter.increment()
                return nil
            }
        )
        XCTAssertEqual(counter.value, 0, "building the client must not look anything up")

        _ = try client.fetchReport()
        XCTAssertEqual(counter.value, SymBrainUsageClient.credentialEnvironment.count)
    }

    func testSupportedProvidersAreTheOnesThatReceiveAReference() {
        XCTAssertEqual(Set(SymVaultEntryPaths.supportedProviderIDs), ["openrouter", "moonshot", "kimi", "zai", "devin", "grok", "opencode"])
    }

    // MARK: Entry-path normalization

    func testNormalizeTrimsAndAcceptsAPastedReference() {
        XCTAssertEqual(SymVaultEntryPaths.normalize("  openrouter/work \n"), "openrouter/work")
        XCTAssertEqual(SymVaultEntryPaths.normalize("symvault://openrouter/work"), "openrouter/work")
        XCTAssertEqual(SymVaultEntryPaths.normalize("/kimi-coding/main/"), "kimi-coding/main")
    }

    func testNormalizeRejectsEmptyAndUnusableValues() {
        XCTAssertNil(SymVaultEntryPaths.normalize(""))
        XCTAssertNil(SymVaultEntryPaths.normalize("   \n"))
        XCTAssertNil(SymVaultEntryPaths.normalize("symvault://"))
        XCTAssertNil(SymVaultEntryPaths.normalize("openrouter/my key"))
        XCTAssertNil(SymVaultEntryPaths.normalize("openrouter/../other"))
        XCTAssertNil(SymVaultEntryPaths.normalize("openrouter//work"))
        XCTAssertNil(SymVaultEntryPaths.normalize("openrouter/wo\u{0}rk"))
    }

    func testInvalidOverridesFallBackToTheDefaultPath() {
        let paths = SymVaultEntryPaths(["openrouter": "   ", "kimi": "kimi coding/x", "moonshot": "moonshot/work"])

        XCTAssertNil(paths.customPath(for: "openrouter"))
        XCTAssertEqual(paths.path(for: "openrouter"), "symtune/openrouter")
        XCTAssertEqual(paths.path(for: "kimi"), "symtune/kimi")
        XCTAssertEqual(paths.path(for: "moonshot"), "moonshot/work")
        XCTAssertEqual(paths.overrides, ["moonshot": "moonshot/work"])
    }

    func testPersistedPathsRoundTripThroughAnIsolatedDefaultsSuite() throws {
        let suiteName = "com.symaira.symtune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SymVaultEntryPaths.load(from: defaults), SymVaultEntryPaths())
        defaults.set(["openrouter": " openrouter/work ", "kimi": ""], forKey: SymVaultEntryPaths.defaultsKey)

        let loaded = SymVaultEntryPaths.load(from: defaults)
        XCTAssertEqual(loaded.reference(for: "openrouter"), "symvault://openrouter/work")
        XCTAssertEqual(loaded.reference(for: "kimi"), "symvault://symtune/kimi")
        XCTAssertTrue(SymVaultEntryPaths.defaultsKey.hasPrefix("com.symaira.symtune."))
    }

    // MARK: Missing-entry reason

    func testUnconfiguredKeyProviderNamesTheMissingEntry() {
        let paths = SymVaultEntryPaths(["openrouter": "openrouter/x"])

        XCTAssertEqual(
            AIUsageFormatting.unavailableReason(
                providerID: "openrouter", error: AIUsageService.notConfiguredMessage, entryPaths: paths
            ),
            "No SymVault entry at openrouter/x"
        )
        XCTAssertEqual(
            AIUsageFormatting.unavailableReason(
                providerID: "moonshot", error: AIUsageService.notConfiguredMessage, entryPaths: paths
            ),
            "No SymVault entry at symtune/moonshot"
        )
    }

    func testOtherErrorsAndProvidersPassThroughUnchanged() {
        let paths = SymVaultEntryPaths(["openrouter": "openrouter/x"])

        XCTAssertEqual(
            AIUsageFormatting.unavailableReason(providerID: "openrouter", error: "HTTP 401", entryPaths: paths),
            "HTTP 401"
        )
        XCTAssertEqual(
            AIUsageFormatting.unavailableReason(
                providerID: "claude", error: AIUsageService.notConfiguredMessage, entryPaths: paths
            ),
            AIUsageService.notConfiguredMessage
        )
        XCTAssertNil(AIUsageFormatting.unavailableReason(providerID: "openrouter", error: nil, entryPaths: paths))
        XCTAssertNil(AIUsageFormatting.unavailableReason(providerID: "openrouter", error: "", entryPaths: paths))
    }

    func testServiceReportsUnconfiguredKeyProviderSoTheReasonCanBeShown() async throws {
        let report = #"""
        {"schema_version": 1, "providers": [{
          "id": "openrouter", "display_name": "OpenRouter", "configured": false,
          "auth_status": {"status": "missing", "detail": "no key"}
        }]}
        """#
        let client = SymBrainUsageClient(
            runner: FixedReportRunner(report: report),
            environment: [:],
            credentialReference: { _ in nil }
        )
        let openrouter = try XCTUnwrap(SymBrainUsageProvider.catalog().first { $0.id == "openrouter" })
        let results = await AIUsageService(providers: [openrouter], client: client).usageAll()

        let result = try XCTUnwrap(results.first)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.error, AIUsageService.notConfiguredMessage)
        XCTAssertEqual(
            AIUsageFormatting.unavailableReason(
                providerID: result.providerID,
                error: result.error,
                entryPaths: SymVaultEntryPaths(["openrouter": "openrouter/x"])
            ),
            "No SymVault entry at openrouter/x"
        )
    }

    // MARK: Visibility with "hide unconfigured"

    func testEnabledUnconfiguredProviderStaysVisibleWhenHidingUnconfigured() {
        XCTAssertTrue(AIUsageVisibility.isVisible(hideUnconfigured: true, isEnabled: true, isConfigured: false))
    }

    func testUnrequestedUnconfiguredProviderIsHiddenWhenHidingUnconfigured() {
        XCTAssertFalse(AIUsageVisibility.isVisible(hideUnconfigured: true, isEnabled: false, isConfigured: false))
    }

    func testConfiguredAndUnfilteredProvidersAreAlwaysVisible() {
        XCTAssertTrue(AIUsageVisibility.isVisible(hideUnconfigured: true, isEnabled: false, isConfigured: true))
        XCTAssertTrue(AIUsageVisibility.isVisible(hideUnconfigured: true, isEnabled: true, isConfigured: true))
        XCTAssertTrue(AIUsageVisibility.isVisible(hideUnconfigured: false, isEnabled: false, isConfigured: false))
        XCTAssertTrue(AIUsageVisibility.isVisible(hideUnconfigured: false, isEnabled: true, isConfigured: false))
    }
}

private struct FixedReportRunner: SymBrainCommandRunner {
    let report: String

    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        SymBrainCommandResult(standardOutput: Data(report.utf8), standardError: Data(), terminationStatus: 0)
    }
}

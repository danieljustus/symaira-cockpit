import Foundation
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

/// Opt-in only: scripts/check-paired-history.py validates binary receipts and supplies isolated fixtures.
final class AIUsagePairedHistoryTests: XCTestCase {
    private func configuration() throws -> (String, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["PAIRED_HISTORY_ROOT"], let runner = environment["PAIRED_HISTORY_RUNNER"] else {
            throw XCTSkip("Requires explicit receipt-validated Brain binaries via scripts/check-paired-history.py")
        }
        XCTAssertTrue(root.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: runner))
        return (root, runner)
    }

    private func client(root: String, runner: String, scenario: String) -> SymBrainUsageClient {
        let home = root + "/" + scenario
        return SymBrainUsageClient(runner: ProcessSymBrainCommandRunner(binaryName: runner, timeout: 20), environment: [
            "HOME": home + "/home", "CFFIXED_USER_HOME": home + "/home",
            "XDG_DATA_HOME": home + "/data", "XDG_CONFIG_HOME": home + "/config",
            "XDG_CACHE_HOME": home + "/cache", "GROK_HOME": home + "/grok", "TMPDIR": home + "/tmp",
            "PATH": root + "/traps", "TZ": "UTC", "SYMBRAIN_GO_BINARY": root + "/traps/symbrain-go",
            "GROK_ACCESS_TOKEN": scenario == "quota-error" ? "synthetic-invalid-not-a-credential" : "",
            // An inherited flag must never substitute for the production client's explicit consent arguments.
            "SYMBRAIN_USAGE_GROK_HISTORY": "1", "SYMBRAIN_USAGE_OPENCODE_HISTORY": "1"
        ], credentialReference: { _ in nil })
    }

    @MainActor
    func testRealBrainClientServiceAndSpend() async throws {
        let (root, runner) = try configuration()
        let selected: Set<String> = ["grok", "opencode"]
        let client = client(root: root, runner: runner, scenario: "complete")
        let report = try client.fetchReport(providerIDs: selected, grokHistoryEnabled: true, opencodeHistoryEnabled: true)
        XCTAssertEqual(report.providers.first { $0.id == "grok" }?.authStatus.status, "missing")
        XCTAssertEqual(report.providers.first { $0.id == "opencode" }?.authStatus.status, "missing")
        XCTAssertFalse(try XCTUnwrap(report.providers.first { $0.id == "opencode" }).authStatus.detail.isEmpty)
        let quotaClient = self.client(root: root, runner: runner, scenario: "quota-error")
        let quotaReport = try quotaClient.fetchReport(providerIDs: ["grok"], grokHistoryEnabled: true)
        let quotaRow = try XCTUnwrap(quotaReport.providers.first)
        XCTAssertTrue(quotaRow.configured)
        XCTAssertFalse(quotaRow.error.isEmpty, "Kernel-denied quota request must produce a real provider error")
        XCTAssertNil(quotaRow.snapshot)
        XCTAssertEqual(quotaRow.history?.status, .available)
        let quotaResults = await AIUsageService(client: quotaClient).usageAll(providerIDs: ["grok"], grokHistoryEnabled: true)
        XCTAssertNotNil(quotaResults.first?.history)
        XCTAssertNotNil(quotaResults.first?.error)
        XCTAssertEqual(Set(report.providers.map(\.id)), selected)
        for row in report.providers {
            XCTAssertNil(row.snapshot)
            XCTAssertFalse(row.configured)
            let history = try XCTUnwrap(row.history, row.id)
            XCTAssertEqual(history.status, .available)
            let today = try XCTUnwrap(history.periods.first { $0.key == "today" })
            XCTAssertEqual(today.models.reduce(0) { $0 + $1.events }, 1, "Cross-channel/table copies must deduplicate")
        }
        let service = AIUsageService(client: client)
        let results = await service.usageAll(providerIDs: selected, grokHistoryEnabled: true, opencodeHistoryEnabled: true)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.snapshot == nil && $0.error != nil && $0.history != nil })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root + "/preferences-home/PairedHistory.model"))
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = selected
        preferences.grokHistoryEnabled = true
        preferences.opencodeHistoryEnabled = true
        let model = AIUsageViewModel(providers: service.providers, preferences: preferences,
            fetchHistory: { await service.usageAll(providerIDs: $0, force: $1, grokHistoryEnabled: $2, opencodeHistoryEnabled: $3) },
            fetch: { await service.usageAll(providerIDs: $0, force: $1) })
        defer { model.stop() }
        await model.refresh()
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.3000000002"))
        model.apply(quotaResults + results.filter { $0.providerID == "opencode" })
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.3000000002"), "Quota failure cannot erase recorded spend")
        preferences.localSpendMode = .tokens
        XCTAssertEqual(model.localRecordedSpend.total, 42)
        preferences.localSpendMode = .costPerMillion
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.3000000002")! * 1_000_000 / 42)
        preferences.localSpendMode = .cost
        preferences.localSpendPeriod = .yesterday
        XCTAssertNil(model.localRecordedSpend.total, "An absent period is not zero")
        preferences.localSpendPeriod = .today
        preferences.opencodeHistoryEnabled = false
        XCTAssertNil(model.rows.first { $0.id == "opencode" }?.recordedHistory)
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.2000000001"))
        preferences.grokHistoryEnabled = false
        XCTAssertNil(model.localRecordedSpend.total)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        XCTAssertTrue(model.rows.allSatisfy { $0.recordedHistory == nil })

        let disabled = try client.fetchReport(providerIDs: selected)
        XCTAssertTrue(disabled.providers.allSatisfy { $0.history == nil })
        for id in selected {
            let scoped = try client.fetchReport(providerIDs: [id], grokHistoryEnabled: true, opencodeHistoryEnabled: true)
            XCTAssertEqual(scoped.providers.map(\.id), [id])
            XCTAssertNotNil(scoped.providers.first?.history)
        }
        let denied = await service.usageAll(providerIDs: selected)
        XCTAssertTrue(denied.allSatisfy { $0.history == nil })
        let empty = await service.usageAll(providerIDs: [], grokHistoryEnabled: true, opencodeHistoryEnabled: true)
        XCTAssertTrue(empty.isEmpty)

        for scenario in ["missing", "partial"] {
            let incompleteService = AIUsageService(client: self.client(root: root, runner: runner, scenario: scenario))
            let incomplete = await incompleteService.usageAll(providerIDs: selected, grokHistoryEnabled: true, opencodeHistoryEnabled: true)
            XCTAssertEqual(incomplete.count, 2)
            let histories = try Dictionary(uniqueKeysWithValues: incomplete.map { ($0.providerID, try XCTUnwrap($0.history)) })
            XCTAssertTrue(histories.values.allSatisfy { $0.status == .partial })
            let spend = AIUsageLocalRecordedSpend(providerIDs: selected, histories: histories, period: .today, mode: .cost)
            XCTAssertNil(spend.total, scenario)
            XCTAssertTrue(spend.contributions.allSatisfy { $0.value == nil })
        }
    }

    @MainActor
    func testSeparateProcessPreferences() throws {
        let (root, _) = try configuration()
        let environment = ProcessInfo.processInfo.environment
        let suite = try XCTUnwrap(environment["PAIRED_HISTORY_SUITE"])
        XCTAssertEqual(suite, root + "/preferences-home/PairedHistory.persistence")
        let phase = try XCTUnwrap(environment["PAIRED_HISTORY_PHASE"])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AIUsagePreferences(defaults: defaults)
        switch phase {
        case "write":
            XCTAssertFalse(preferences.grokHistoryEnabled)
            XCTAssertFalse(preferences.opencodeHistoryEnabled)
            preferences.enabledProviders = ["grok", "opencode"]
            preferences.grokHistoryEnabled = true
            preferences.opencodeHistoryEnabled = true
            preferences.localSpendPeriod = .last30Days
            preferences.localSpendMode = .tokens
        case "read-revoke":
            XCTAssertEqual(preferences.consentedHistoryProviders, ["grok", "opencode"])
            XCTAssertEqual(preferences.localSpendPeriod, .last30Days)
            XCTAssertEqual(preferences.localSpendMode, .tokens)
            preferences.grokHistoryEnabled = false
            preferences.opencodeHistoryEnabled = false
            preferences.localSpendPeriod = .yesterday
            preferences.localSpendMode = .costPerMillion
        case "read-revoked":
            XCTAssertFalse(preferences.grokHistoryEnabled)
            XCTAssertFalse(preferences.opencodeHistoryEnabled)
            XCTAssertEqual(preferences.enabledProviders, ["grok", "opencode"])
            XCTAssertEqual(preferences.localSpendPeriod, .yesterday)
            XCTAssertEqual(preferences.localSpendMode, .costPerMillion)
        default: XCTFail("Unknown persistence phase")
        }
        XCTAssertTrue(defaults.synchronize())
        print("PAIRED_PREFERENCES phase=\(phase) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}

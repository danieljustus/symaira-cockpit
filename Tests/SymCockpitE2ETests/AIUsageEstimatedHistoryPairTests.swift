import AppKit
import Foundation
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

/// Synthetic native pairing only; no live controllers or user history.
final class AIUsageEstimatedHistoryPairTests: XCTestCase {
    private func configuration() throws -> (String, String) {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["ESTIMATED_HISTORY_ROOT"], let runner = env["ESTIMATED_HISTORY_RUNNER"] else {
            throw XCTSkip("Requires scripts/check-estimated-history.py and receipt-validated binaries")
        }
        XCTAssertTrue(root.hasPrefix("/"))
        return (root, runner)
    }

    private func client(root: String, runner: String, scenario: String) -> SymBrainUsageClient {
        let base = root + "/" + scenario
        return SymBrainUsageClient(runner: ProcessSymBrainCommandRunner(binaryName: runner, timeout: 20), environment: [
            "HOME": base + "/home", "CFFIXED_USER_HOME": base + "/home", "CODEX_HOME": base + "/codex",
            "CLAUDE_CONFIG_DIR": base + "/claude", "XDG_CONFIG_HOME": base + "/config",
            "XDG_DATA_HOME": base + "/data", "XDG_CACHE_HOME": base + "/cache", "TMPDIR": base + "/tmp",
            "PATH": root + "/traps", "TZ": "UTC", "SYMBRAIN_GO_BINARY": root + "/traps/symbrain-go",
            "CODEX_ACCESS_TOKEN": scenario == "quota-error" ? "synthetic-invalid-token" : "symvault://synthetic-must-not-resolve",
            "ANTHROPIC_OAUTH_TOKEN": scenario == "quota-error" ? "synthetic-invalid-token" : "symvault://synthetic-must-not-resolve",
            "SYMBRAIN_USAGE_CLAUDE_HISTORY": "1", "SYMBRAIN_USAGE_CLAUDE_HISTORY_ONLY": "1",
            "SYMBRAIN_USAGE_CODEX_HISTORY": "1", "SYMBRAIN_USAGE_CODEX_HISTORY_ONLY": "1",
            "SYMBRAIN_USAGE_GROK_HISTORY": "1", "SYMBRAIN_USAGE_OPENCODE_HISTORY": "1"
        ], credentialReference: { _ in nil })
    }

    @MainActor
    func testNativeClientServiceModelAndOverview() async throws {
        let (root, runner) = try configuration()
        let selected: Set<String> = ["claude", "codex"]
        for scenario in ["complete", "unknown", "partial", "quota-error"] {
            let client = client(root: root, runner: runner, scenario: scenario)
            let localOnly = scenario != "quota-error"
            let report = try client.fetchReport(providerIDs: selected, grokHistoryEnabled: false, opencodeHistoryEnabled: false,
                claudeHistoryEnabled: true, claudeHistoryOnly: localOnly, codexHistoryEnabled: true, codexHistoryOnly: localOnly)
            XCTAssertEqual(Set(report.providers.map(\.id)), selected)
            for row in report.providers {
                XCTAssertNil(row.snapshot)
                if localOnly { XCTAssertFalse(row.configured) } else { XCTAssertFalse(row.error.isEmpty) }
                let history = try XCTUnwrap(row.history, row.id + scenario)
                XCTAssertNotNil(history.priceSnapshot)
                let bucket = try XCTUnwrap(history.periods.first { $0.key == "today" })
                let known = try XCTUnwrap(bucket.models.first { $0.model == (row.id == "codex" ? "gpt-5.4" : "claude-sonnet-4-5") })
                XCTAssertEqual(known.recordedCost, "0.1000000001")
                XCTAssertEqual(known.estimatedCost, row.id == "codex" ? "0.0007575" : "0.0006")
                XCTAssertEqual(known.events, row.id == "codex" ? 4 : 3)
                XCTAssertEqual(known.costBasis, "mixed")
                XCTAssertTrue(history.costDetail(bucket).contains("recorded /"))
                XCTAssertEqual(history.status, ["unknown", "partial"].contains(scenario) ? .partial : .available)
            }
            let service = AIUsageService(client: client)
            let results = await service.usageAll(providerIDs: selected, force: false, claudeHistoryEnabled: true,
                claudeHistoryOnly: localOnly, codexHistoryEnabled: true, codexHistoryOnly: localOnly)
            XCTAssertTrue(results.allSatisfy { $0.history != nil && $0.error != nil })
            let defaults = try XCTUnwrap(UserDefaults(suiteName: root + "/preferences/model-" + scenario))
            let preferences = AIUsagePreferences(defaults: defaults)
            preferences.enabledProviders = selected
            preferences.claudeHistoryEnabled = true
            preferences.codexHistoryEnabled = true
            preferences.claudeHistoryOnly = localOnly
            preferences.codexHistoryOnly = localOnly
            preferences.localSpendMode = .cost
            preferences.localSpendPeriod = .today
            let model = AIUsageViewModel(providers: service.providers, preferences: preferences,
                fetchEstimatedHistory: { await service.usageAll(providerIDs: $0, force: $1, grokHistoryEnabled: $2,
                    opencodeHistoryEnabled: $3, claudeHistoryEnabled: $4, claudeHistoryOnly: $5,
                    codexHistoryEnabled: $6, codexHistoryOnly: $7) },
                fetch: { await service.usageAll(providerIDs: $0, force: $1) })
            await model.refresh()
            preferences.displayVisibility = ["claude": false, "codex": false]
            XCTAssertTrue(model.visibleRows.isEmpty)
            XCTAssertEqual(Set(model.localRecordedSpend.contributions.map(\.id)), selected)
            XCTAssertTrue(model.localRecordedSpend.contributions.allSatisfy { $0.detail.contains("recorded /") })
            XCTAssertTrue(model.localRecordedSpend.includesEstimates)
            XCTAssertEqual(model.localRecordedSpend.total, ["unknown", "partial"].contains(scenario) ? nil : Decimal(string: "0.2013575002"))
            preferences.localSpendMode = .tokens
            XCTAssertEqual(model.localRecordedSpend.total, scenario == "partial" ? nil : scenario == "unknown" ? 1_020 : 780)
            model.stop()
            preferences.claudeHistoryEnabled = false
            preferences.codexHistoryEnabled = false
            XCTAssertTrue(model.rows.allSatisfy { $0.recordedHistory == nil })
            XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
            let disabled = try client.fetchReport(providerIDs: selected)
            XCTAssertTrue(disabled.providers.allSatisfy { $0.history == nil })
            let onlyChoice = try client.fetchReport(providerIDs: selected, grokHistoryEnabled: false, opencodeHistoryEnabled: false,
                claudeHistoryEnabled: false, claudeHistoryOnly: true, codexHistoryEnabled: false, codexHistoryOnly: true)
            XCTAssertTrue(onlyChoice.providers.allSatisfy { $0.history == nil })
            for id in selected {
                let scoped = try client.fetchReport(providerIDs: [id], grokHistoryEnabled: true, opencodeHistoryEnabled: true,
                    claudeHistoryEnabled: true, claudeHistoryOnly: true, codexHistoryEnabled: true, codexHistoryOnly: true)
                XCTAssertEqual(scoped.providers.map(\.id), [id])
                XCTAssertNotNil(scoped.providers.first?.history)
            }
            XCTAssertTrue(service.cachedResults().allSatisfy { $0.history == nil })
        }
    }

    @MainActor
    func testSeparateProcessConsents() throws {
        let (root, _) = try configuration()
        let env = ProcessInfo.processInfo.environment
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root + "/preferences/Estimated.persistence"))
        let phase = try XCTUnwrap(env["ESTIMATED_HISTORY_PHASE"])
        if phase == "sentinel" {
            defaults.set("isolated-estimated-history", forKey: "sentinel")
        } else {
            XCTAssertEqual(defaults.string(forKey: "sentinel"), "isolated-estimated-history")
            let preferences = AIUsagePreferences(defaults: defaults)
            switch phase {
            case "write":
                XCTAssertFalse(preferences.claudeHistoryEnabled)
                XCTAssertFalse(preferences.codexHistoryEnabled)
                XCTAssertFalse(preferences.claudeHistoryOnly)
                XCTAssertFalse(preferences.codexHistoryOnly)
                preferences.enabledProviders = ["claude", "codex"]
                preferences.claudeHistoryOnly = true
                preferences.codexHistoryOnly = true
                XCTAssertTrue(preferences.consentedHistoryProviders.isEmpty)
                preferences.claudeHistoryEnabled = true
                preferences.codexHistoryEnabled = true
            case "read-revoke":
                XCTAssertEqual(preferences.consentedHistoryProviders, ["claude", "codex"])
                XCTAssertTrue(preferences.claudeHistoryOnly)
                XCTAssertTrue(preferences.codexHistoryOnly)
                preferences.claudeHistoryEnabled = false
                preferences.codexHistoryEnabled = false
                preferences.claudeHistoryOnly = false
                preferences.codexHistoryOnly = false
            case "read-revoked":
                XCTAssertTrue(preferences.consentedHistoryProviders.isEmpty)
                XCTAssertFalse(preferences.claudeHistoryEnabled)
                XCTAssertFalse(preferences.codexHistoryEnabled)
                XCTAssertFalse(preferences.claudeHistoryOnly)
                XCTAssertFalse(preferences.codexHistoryOnly)
            default: XCTFail("Unknown phase")
            }
        }
        XCTAssertTrue(defaults.synchronize())
        print("ESTIMATED_PREFERENCES phase=\(phase) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}

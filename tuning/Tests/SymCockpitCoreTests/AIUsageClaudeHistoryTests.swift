import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageClaudeHistoryTests: XCTestCase {
    private func row(_ basis: String, missing: Int = 0) -> [String: Any] {
        let recorded = ["recorded", "mixed"].contains(basis) ? 1 : 0
        let estimated = ["estimated", "mixed"].contains(basis) ? 1 : 0
        var result: [String: Any] = ["model": "claude-sonnet-4-5", "events": recorded + estimated + missing,
            "tokens": "100", "missing_tokens": 0, "missing_cost": missing, "cost_basis": basis,
            "recorded_events": recorded, "estimated_events": estimated]
        if recorded > 0 { result["recorded_cost"] = "0" }
        if estimated > 0 { result["estimated_cost"] = "0.0000000001" }
        return result
    }

    private func wire(_ row: [String: Any], basis: String, status: String = "available") -> [String: Any] {
        ["scope": "local_machine", "attribution": "unattributed", "currency": "USD", "cost_basis": basis,
         "price_snapshot": "openusage:abf472d5dbb23645c3afbb5a0c7429606ffbdcd7:litellm-2026-07-02:supplement-2026-10-16:modelsdev-2026-07-02",
         "timezone": "local", "status": status, "excluded_events": 0,
         "daily": [["key": "2026-10-25", "models": [row]]], "periods": [["key": "today", "models": [row]]]]
    }

    private func decode(_ value: [String: Any]) throws -> AIUsageRecordedHistory {
        try JSONDecoder().decode(AIUsageRecordedHistory.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testEstimatedMixedRecordedZeroAndLegacyRoundTrips() throws {
        for basis in ["recorded", "estimated", "mixed"] {
            let history = try decode(wire(row(basis), basis: basis))
            let bucket = history.periods[0]
            XCTAssertEqual(history.total(bucket, cost: true), basis == "recorded" ? 0 : Decimal(string: "0.0000000001"))
            XCTAssertEqual(bucket.models[0].recordedCost, basis == "estimated" ? nil : "0")
            XCTAssertEqual(bucket.models[0].estimatedCost, basis == "recorded" ? nil : "0.0000000001")
            XCTAssertEqual(history.costLabel(for: bucket), basis == "mixed" ? "recorded + estimated" : basis)
            XCTAssertEqual(try JSONDecoder().decode(AIUsageRecordedHistory.self, from: JSONEncoder().encode(history)), history)
            let spend = AIUsageLocalRecordedSpend(providerIDs: ["claude"], histories: ["claude": history], period: .today, mode: .cost)
            XCTAssertEqual(spend.total, history.total(bucket, cost: true))
            XCTAssertEqual(spend.includesEstimates, basis != "recorded")
            XCTAssertTrue(history.costDetail(bucket).contains("recorded /"))
            if basis != "recorded" { XCTAssertTrue(spend.formatted(try XCTUnwrap(spend.total)).contains("estimated")) }
        }
        var split = wire(row("estimated"), basis: "mixed")
        split["periods"] = [["key": "today", "models": [row("recorded")]],
                            ["key": "last_30_days", "models": [row("mixed")]]]
        let splitHistory = try decode(split)
        let today = AIUsageLocalRecordedSpend(providerIDs: ["claude"], histories: ["claude": splitHistory], period: .today, mode: .cost)
        XCTAssertFalse(today.includesEstimates, "Another day's estimate must not relabel today's recorded total")
        XCTAssertEqual(today.formatted(0), "0 USD recorded")
        var legacy = row("recorded")
        for key in ["cost_basis", "recorded_events", "estimated_events"] { legacy.removeValue(forKey: key) }
        var oldWire = wire(legacy, basis: "recorded")
        oldWire.removeValue(forKey: "price_snapshot")
        let old = try decode(oldWire)
        XCTAssertNil(old.priceSnapshot)
        XCTAssertEqual(old.summary(old.periods[0]), "0 USD recorded · 100 tokens")
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(encoded.contains("estimated_cost"))
        XCTAssertFalse(encoded.contains("recorded_events"))
    }

    func testUnknownAndPartialSubtotalsWithholdMoneyButRetainKnownTokens() throws {
        for basis in ["unknown", "recorded", "mixed", "estimated"] {
            let history = try decode(wire(row(basis, missing: 1), basis: basis, status: "partial"))
            XCTAssertNil(history.total(history.periods[0], cost: true))
            XCTAssertEqual(history.total(history.periods[0], cost: false), 100)
            let cost = AIUsageLocalRecordedSpend(providerIDs: ["claude"], histories: ["claude": history], period: .today, mode: .cost)
            XCTAssertNil(cost.total)
            XCTAssertTrue(cost.contributions[0].detail.contains("1 missing cost events"))
            let tokens = AIUsageLocalRecordedSpend(providerIDs: ["claude"], histories: ["claude": history], period: .today, mode: .tokens)
            XCTAssertEqual(tokens.total, 100)
        }
        var zero = row("estimated"); zero["tokens"] = "0"
        let history = try decode(wire(zero, basis: "estimated"))
        let rate = AIUsageLocalRecordedSpend(providerIDs: ["claude"], histories: ["claude": history], period: .today, mode: .costPerMillion)
        XCTAssertNil(rate.total)
        XCTAssertTrue(rate.message.contains("undefined"))
    }

    func testCoverageInconsistencyAndInvalidHistoryIsolation() throws {
        var invalidRows: [[String: Any]] = []
        for (key, value): (String, Any) in [("recorded_events", 3), ("estimated_events", -1), ("cost_basis", "recorded"),
                                           ("estimated_cost", "-1"), ("estimated_cost", 0.5), ("missing_cost", 1)] {
            var bad = row("mixed"); bad[key] = value; invalidRows.append(bad)
        }
        var missing = row("mixed"); missing.removeValue(forKey: "estimated_events"); invalidRows.append(missing)
        for bad in invalidRows {
            let history = wire(bad, basis: "mixed")
            XCTAssertThrowsError(try decode(history))
            let provider: [String: Any] = ["id": "claude", "display_name": "Claude", "configured": true,
                "auth_status": ["status": "available", "detail": "Example"], "history": history,
                "snapshot": ["provider_id": "claude", "meters": [], "fetched_at": "2026-10-25T12:00:00Z", "source": "Example"]]
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": [provider]])
            let decoded = try XCTUnwrap(decoder.decode(SymBrainUsageReport.self, from: data).providers.first)
            XCTAssertNil(decoded.history)
            XCTAssertNotNil(decoded.snapshot)
        }
    }

    func testAllHistoryFlagsAreStrippedUnlessExplicitlySelectedAndConsented() throws {
        let runner = ClaudeHistoryRunner(data: Data(#"{"schema_version":1,"providers":[]}"#.utf8))
        let flags = ["SYMBRAIN_USAGE_CLAUDE_HISTORY", "SYMBRAIN_USAGE_CLAUDE_HISTORY_ONLY",
                     "SYMBRAIN_USAGE_GROK_HISTORY", "SYMBRAIN_USAGE_OPENCODE_HISTORY", "SYMBRAIN_USAGE_CODEX_HISTORY"]
        let client = SymBrainUsageClient(runner: runner, environment: Dictionary(uniqueKeysWithValues: flags.map { ($0, "1") }),
                                         credentialReference: { _ in nil })
        XCTAssertEqual(runner.calls, 0)
        for selection: Set<String> in [["claude"], ["grok"], ["opencode"], ["codex"]] {
            for consent in [false, true] {
                for localOnly in [false, true] {
                    _ = try client.fetchReport(providerIDs: selection, grokHistoryEnabled: consent, opencodeHistoryEnabled: consent,
                                               claudeHistoryEnabled: consent, claudeHistoryOnly: localOnly)
                    for (provider, flag) in [("claude", flags[0]), ("grok", flags[2]), ("opencode", flags[3])] {
                        XCTAssertEqual(runner.environment[flag], consent && selection.contains(provider) ? "1" : nil)
                    }
                    XCTAssertEqual(runner.environment[flags[1]], consent && localOnly && selection.contains("claude") ? "1" : nil)
                    XCTAssertNil(runner.environment[flags[4]])
                }
            }
        }
        _ = try client.fetchReport()
        XCTAssertTrue(flags.allSatisfy { runner.environment[$0] == nil })
        let calls = runner.calls
        _ = try client.fetchReport(providerIDs: [], grokHistoryEnabled: true, opencodeHistoryEnabled: true,
                                   claudeHistoryEnabled: true, claudeHistoryOnly: true)
        XCTAssertEqual(runner.calls, calls)
    }

    func testClaudeHistoryBypassesFreshCacheAndSurvivesQuotaErrors() async throws {
        let history = wire(row("mixed"), basis: "mixed")
        let provider: [String: Any] = ["id": "claude", "display_name": "Claude", "configured": false,
            "auth_status": ["status": "missing", "detail": "Example"], "history": history, "error": "Example quota unavailable"]
        let runner = ClaudeHistoryRunner(data: try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": [provider]]))
        let client = SymBrainUsageClient(runner: runner, environment: [:], credentialReference: { _ in nil })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-cache-" + UUID().uuidString)
        let cache = AIUsageSnapshotCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.save(.init(providerID: "claude", meters: [], source: "Example"))
        let service = AIUsageService(providers: [SymBrainUsageProvider(id: "claude", displayName: "Claude")], client: client, cache: cache)
        _ = await service.usageAll(providerIDs: ["claude"], force: false)
        XCTAssertEqual(runner.calls, 0)
        let result = await service.usageAll(providerIDs: ["claude"], force: false, claudeHistoryEnabled: true, claudeHistoryOnly: true)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertNotNil(result.first?.history)
        XCTAssertNotNil(result.first?.error)
        XCTAssertNil(service.cachedResults().first?.history)
        let disabled = await service.usageAll(providerIDs: ["claude"])
        XCTAssertNil(disabled.first?.history)
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_CLAUDE_HISTORY"])
    }
}

private final class ClaudeHistoryRunner: SymBrainCommandRunner, @unchecked Sendable {
    let data: Data
    var calls = 0
    var environment: [String: String] = [:]
    init(data: Data) { self.data = data }
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        calls += 1
        self.environment = environment
        return .init(standardOutput: data, standardError: Data(), terminationStatus: 0)
    }
}

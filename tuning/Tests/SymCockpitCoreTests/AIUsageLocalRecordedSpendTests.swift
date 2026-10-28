import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageLocalRecordedSpendTests: XCTestCase {
    private func history(cost: String? = "0.1", tokens: String? = "10", status: String = "available",
                         excluded: Int = 0, timezone: String = "local", period: String = "today") throws -> AIUsageRecordedHistory {
        var model: [String: Any] = ["model": "example-model", "events": 1,
                                   "missing_cost": cost == nil ? 1 : 0, "missing_tokens": tokens == nil ? 1 : 0]
        model["tokens"] = tokens
        model["recorded_cost"] = cost
        let buckets: [[String: Any]] = ["no_data", "unavailable"].contains(status) ? [] : [["key": period, "models": [model]]]
        let data = try JSONSerialization.data(withJSONObject: ["scope": "local_machine", "attribution": "unattributed",
            "currency": "USD", "cost_basis": "recorded", "timezone": timezone, "status": status,
            "excluded_events": excluded, "daily": [], "periods": buckets])
        return try JSONDecoder().decode(AIUsageRecordedHistory.self, from: data)
    }

    func testBothProvidersExactDecimalsAndWeightedRate() throws {
        let histories = ["grok": try history(cost: "0.0000000001", tokens: "10"),
                         "opencode": try history(cost: "0.2", tokens: "30")]
        let cost = AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"], histories: histories, period: .today, mode: .cost)
        XCTAssertEqual(cost.total, Decimal(string: "0.2000000001"))
        XCTAssertEqual(cost.contributions.count, 2)
        let tokens = AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"], histories: histories, period: .today, mode: .tokens)
        XCTAssertEqual(tokens.total, 40)
        let rate = AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"], histories: histories, period: .today, mode: .costPerMillion)
        XCTAssertEqual(rate.total, Decimal(string: "5000.0000025"))
    }

    func testMissingAbsentPartialExcludedUnknownAndIncompatibleWithholdTotal() throws {
        for invalid in [try history(status: "partial"), try history(excluded: 1), try history(cost: nil),
                        try history(status: "no_data"), try history(status: "unavailable"),
                        try history(timezone: "UTC"), try history(period: "yesterday")] {
            let result = AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"],
                histories: ["grok": try history(), "opencode": invalid], period: .today, mode: .cost)
            XCTAssertNil(result.total)
            XCTAssertTrue(result.message.contains("Incomplete"))
        }
        let absent = AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"], histories: ["grok": try history()], period: .today, mode: .cost)
        XCTAssertNil(absent.total)
        XCTAssertTrue(absent.contributions.last?.detail.contains("absent") == true)
        let measuredCost = AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: ["opencode": try history(tokens: nil)],
            period: .today, mode: .cost)
        XCTAssertEqual(measuredCost.total, Decimal(string: "0.1"))
        let unknownTokens = AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: ["opencode": try history(tokens: nil)],
            period: .today, mode: .tokens)
        XCTAssertNil(unknownTokens.total)
    }

    func testZeroAllDisabledAndExplicitPeriodNeverInventData() throws {
        let histories = ["opencode": try history(cost: "0", tokens: "0")]
        for mode in [AIUsageLocalRecordedSpend.Mode.cost, .tokens] {
            XCTAssertEqual(AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: histories, period: .today, mode: mode).total, 0)
        }
        let rate = AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: histories, period: .today, mode: .costPerMillion)
        XCTAssertNil(rate.total)
        XCTAssertTrue(rate.contributions[0].detail.contains("Zero recorded tokens"))
        var mixed = histories
        mixed["grok"] = try history(cost: "0.1", tokens: "10")
        XCTAssertEqual(AIUsageLocalRecordedSpend(providerIDs: ["grok", "opencode"], histories: mixed,
            period: .today, mode: .costPerMillion).total, 10_000)
        XCTAssertTrue(rate.message.contains("rate undefined"))
        let off = AIUsageLocalRecordedSpend(providerIDs: [], histories: histories, period: .today, mode: .cost)
        XCTAssertNil(off.total)
        XCTAssertTrue(off.contributions.isEmpty)
        XCTAssertTrue(off.message.contains("Off"))
        XCTAssertNil(AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: histories, period: .yesterday, mode: .tokens).total)
        XCTAssertNil(AIUsageLocalRecordedSpend(providerIDs: ["opencode"], histories: histories, period: .last30Days, mode: .tokens).total)
    }

    func testOpenCodeEnvironmentConsentSelectionAndLegacyAdaptersFailClosed() throws {
        let runner = LocalSpendRunner()
        let client = SymBrainUsageClient(runner: runner, environment:
            ["SYMBRAIN_USAGE_OPENCODE_HISTORY": "1", "SYMBRAIN_USAGE_GROK_HISTORY": "1"], credentialReference: { _ in nil })
        _ = try client.fetchReport(providerIDs: ["opencode"])
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_OPENCODE_HISTORY"])
        _ = try client.fetchReport(providerIDs: ["grok"], grokHistoryEnabled: true, opencodeHistoryEnabled: true)
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_OPENCODE_HISTORY"])
        XCTAssertEqual(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"], "1")
        _ = try client.fetchReport(providerIDs: ["opencode"], grokHistoryEnabled: true, opencodeHistoryEnabled: true)
        XCTAssertEqual(runner.environment["SYMBRAIN_USAGE_OPENCODE_HISTORY"], "1")
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"])
        _ = try client.fetchReport()
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_OPENCODE_HISTORY"])
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"])
    }

    func testOpenCodeHistoryReachesServiceAcrossQuotaErrorsAndBypassesFreshCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AIUsageSnapshotCache(directory: directory)
        try cache.save(.init(providerID: "opencode", meters: [], balance: 999, currency: "USD", source: "quota fixture"))
        let runner = LocalSpendRunner()
        let history = try history()
        let historyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history))
        runner.data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": [
            ["id": "opencode", "display_name": "OpenCode", "configured": true, "error": "quota unavailable",
             "auth_status": ["status": "missing", "detail": "fixture"], "history": historyObject]]])
        let service = AIUsageService(providers: [SymBrainUsageProvider(id: "opencode", displayName: "OpenCode")],
            client: SymBrainUsageClient(runner: runner, environment: [:], credentialReference: { _ in nil }), cache: cache)
        let result = await service.usageAll(providerIDs: ["opencode"], force: false, opencodeHistoryEnabled: true)
        XCTAssertEqual(result.first?.history, history)
        XCTAssertEqual(result.first?.snapshot?.balance, 999)
        XCTAssertNotNil(result.first?.error)
        XCTAssertEqual(runner.environment["SYMBRAIN_USAGE_OPENCODE_HISTORY"], "1")
        XCTAssertNil(service.cachedResults().first?.history)
        let disabled = await service.usageAll(providerIDs: ["opencode"], opencodeHistoryEnabled: false)
        XCTAssertNil(disabled.first?.history)
    }
}

private final class LocalSpendRunner: SymBrainCommandRunner, @unchecked Sendable {
    var data = Data(#"{"schema_version":1,"providers":[]}"#.utf8)
    var environment: [String: String] = [:]
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        self.environment = environment
        return .init(standardOutput: data, standardError: Data(), terminationStatus: 0)
    }
}

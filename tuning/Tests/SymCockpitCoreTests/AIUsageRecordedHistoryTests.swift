import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageRecordedHistoryTests: XCTestCase {
    private func row(tokens: String? = "0", cost: String? = "0") -> [String: Any] {
        var row: [String: Any] = ["model": "grok-4", "events": 1,
                                  "missing_tokens": tokens == nil ? 1 : 0, "missing_cost": cost == nil ? 1 : 0]
        row["tokens"] = tokens
        row["recorded_cost"] = cost
        return row
    }
    private func history(_ models: [[String: Any]], status: String = "available", excluded: Int = 0) -> [String: Any] {
        ["scope": "local_machine", "attribution": "unattributed", "currency": "USD", "cost_basis": "recorded",
         "timezone": "local", "status": status, "excluded_events": excluded,
         "daily": [["key": "2026-10-25", "models": models]],
         "periods": [["key": "last_30_days", "models": models], ["key": "today", "models": models]]]
    }
    private func report(history: Any? = nil, configured: Bool = true, error: String = "") throws -> Data {
        var provider: [String: Any] = ["id": "grok", "display_name": "Grok", "configured": configured,
            "auth_status": ["status": "missing", "detail": "synthetic fixture"], "error": error,
            "snapshot": ["provider_id": "grok", "meters": [], "fetched_at": "2026-10-25T12:00:00Z", "source": "fixture"]]
        provider["history"] = history
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": [provider]])
    }
    private func decode(_ data: Data) throws -> SymBrainProviderUsage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try XCTUnwrap(decoder.decode(SymBrainUsageReport.self, from: data).providers.first)
    }

    func testAbsentHistoryBackwardsDecodeAndMalformedExtensionIsolation() throws {
        XCTAssertNil(try decode(report()).history)
        for malformed: Any in [false, "bad", history([row(tokens: "-1")]), history([row(cost: "1e5")]),
                                history([row(cost: "0.00000000001")]), history([row(tokens: "999999999999999999")])] {
            let provider = try decode(report(history: malformed))
            XCTAssertNil(provider.history)
            XCTAssertEqual(try provider.snapshot?.aiUsageSnapshot().source, "fixture")
        }
        var bad = history([row()]); bad["daily"] = [["key": "2026-02-30", "models": [row()]]]
        XCTAssertNil(try decode(report(history: bad)).history)
        bad = history([row()]); bad["daily"] = Array(repeating: ["key": "2026-10-25", "models": [row()]], count: 31)
        XCTAssertNil(try decode(report(history: bad)).history)
    }

    func testExactDecimalsZeroMissingAndPartialNeverBecomeCompleteTotals() throws {
        let zero = try XCTUnwrap(decode(report(history: history([row()]))).history)
        XCTAssertEqual(zero.total(zero.periods[0], cost: true), 0)
        XCTAssertEqual(zero.total(zero.periods[0], cost: false), 0)
        let tiny = try XCTUnwrap(decode(report(history: history([row(tokens: "20000000000000000", cost: "0.0000000001")]))).history)
        XCTAssertEqual(tiny.total(tiny.periods[0], cost: true), Decimal(string: "0.0000000001"))
        XCTAssertEqual(tiny.total(tiny.periods[0], cost: false), Decimal(string: "20000000000000000"))
        let missing = try XCTUnwrap(decode(report(history: history([row(tokens: nil)]))).history)
        XCTAssertNil(missing.total(missing.periods[0], cost: false))
        XCTAssertEqual(missing.total(missing.periods[0], cost: true), 0)
        let partial = try XCTUnwrap(decode(report(history: history([row()], status: "partial", excluded: 1))).history)
        XCTAssertNil(partial.total(partial.periods[0], cost: true))
        XCTAssertTrue(partial.summary(partial.periods[0]).contains("incomplete"))
        XCTAssertEqual(partial.periods[0].models[0].recordedCost, "0")
    }

    func testBrainCalendarKeysAreNotConsumerRollingWindowsOrFabricatedDays() throws {
        let value = try XCTUnwrap(decode(report(history: history([row()]))).history)
        XCTAssertEqual(value.timezone, "local")
        XCTAssertEqual(value.daily.map(\.key), ["2026-10-25"])
        XCTAssertEqual(value.periods.first { $0.key == "today" }?.models.first?.tokens, "0")
        XCTAssertNil(value.periods.first { $0.key == "yesterday" })
        XCTAssertEqual(try JSONDecoder().decode(AIUsageRecordedHistory.self, from: JSONEncoder().encode(value)), value)
    }

    func testSelectedProviderEnvironmentRequiresBothConsentsAndRemovesInheritedOptIn() throws {
        let runner = HistoryRunner(data: try report())
        let client = SymBrainUsageClient(runner: runner,
            environment: ["SYMBRAIN_USAGE_GROK_HISTORY": "1", "GROK_ACCESS_TOKEN": "fixture"], credentialReference: { _ in nil })
        XCTAssertEqual(runner.calls, 0, "Construction performs no source or credential I/O")
        _ = try client.fetchReport(providerIDs: ["grok"])
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"])
        _ = try client.fetchReport(providerIDs: ["codex"], grokHistoryEnabled: true)
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"])
        XCTAssertNil(runner.environment["GROK_ACCESS_TOKEN"])
        _ = try client.fetchReport(providerIDs: ["grok"], grokHistoryEnabled: true)
        XCTAssertEqual(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"], "1")
        _ = try client.fetchReport()
        XCTAssertNil(runner.environment["SYMBRAIN_USAGE_GROK_HISTORY"])
        let calls = runner.calls
        _ = try client.fetchReport(providerIDs: [], grokHistoryEnabled: true)
        XCTAssertEqual(runner.calls, calls)
    }

    func testHistorySurvivesUnconfiguredAndQuotaErrorButNotFailedScanOrDisabledConsent() async throws {
        for configured in [false, true] {
            let runner = HistoryRunner(data: try report(history: history([row()]), configured: configured, error: "quota failed"))
            let client = SymBrainUsageClient(runner: runner, environment: [:], credentialReference: { _ in nil })
            let service = AIUsageService(providers: [SymBrainUsageProvider(id: "grok", displayName: "Grok")], client: client)
            let results = await service.usageAll(providerIDs: ["grok"], grokHistoryEnabled: true)
            XCTAssertNotNil(results.first?.history)
            XCTAssertNil(results.first?.snapshot)
            XCTAssertNotNil(results.first?.error)
            let disabled = await service.usageAll(providerIDs: ["grok"])
            XCTAssertNil(disabled.first?.history)
            runner.fails = true
            let failed = await service.usageAll(providerIDs: ["grok"], grokHistoryEnabled: true)
            XCTAssertNil(failed.first?.history)
        }
    }

    func testFreshQuotaCacheCannotHideConsentRefreshAndNeverRetainsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AIUsageSnapshotCache(directory: directory)
        try cache.save(.init(providerID: "grok", meters: [], source: "fixture"))
        let runner = HistoryRunner(data: try report(history: history([row()]), configured: true, error: "quota failed"))
        let client = SymBrainUsageClient(runner: runner, environment: [:], credentialReference: { _ in nil })
        let service = AIUsageService(providers: [SymBrainUsageProvider(id: "grok", displayName: "Grok")], client: client, cache: cache)
        let cached = await service.usageAll(providerIDs: ["grok"], force: false)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertNotNil(cached.first?.snapshot)
        let fresh = await service.usageAll(providerIDs: ["grok"], force: false, grokHistoryEnabled: true)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertNotNil(fresh.first?.history)
        XCTAssertNotNil(fresh.first?.snapshot)
        XCTAssertNil(service.cachedResults().first?.history)
    }
}

private final class HistoryRunner: SymBrainCommandRunner, @unchecked Sendable {
    let data: Data
    var calls = 0
    var environment: [String: String] = [:]
    var fails = false
    init(data: Data) { self.data = data }
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        calls += 1
        self.environment = environment
        if fails { throw SymBrainUsageError.binaryUnavailable }
        return .init(standardOutput: data, standardError: Data(), terminationStatus: 0)
    }
}

import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageCacheTests: XCTestCase {
    private func cache() throws -> (AIUsageSnapshotCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (AIUsageSnapshotCache(directory: directory), directory)
    }

    private func snapshot(at date: Date = Date()) -> AIUsageSnapshot {
        AIUsageSnapshot(providerID: "codex", meters: [
            AIUsageMeter(label: "session", used: 42, limit: 100, unit: .percent)
        ], fetchedAt: date, source: "oauth")
    }

    func testCacheRoundTripPermissionsAndFreshnessBoundary() throws {
        let (cache, directory) = try cache()
        let now = Date()
        let value = snapshot(at: now)
        try cache.save(value)
        XCTAssertEqual(cache.load(providerID: "codex", now: now), value)
        XCTAssertTrue(AIUsageSnapshotCache.isFresh(value, now: now.addingTimeInterval(299)))
        XCTAssertFalse(AIUsageSnapshotCache.isFresh(value, now: now.addingTimeInterval(300)))
        XCTAssertFalse(AIUsageSnapshotCache.isFresh(value, now: now.addingTimeInterval(-1)))
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("codex.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        cache.remove(providerID: "codex")
        XCTAssertNil(cache.load(providerID: "codex"))
    }

    func testRejectsTraversalCorruptionAndFutureSnapshots() throws {
        let (cache, directory) = try cache()
        XCTAssertNil(cache.load(providerID: "../codex"))
        XCTAssertThrowsError(try cache.save(AIUsageSnapshot(providerID: "../codex", meters: [], source: "api")))
        try cache.save(snapshot(at: Date().addingTimeInterval(3600)))
        XCTAssertNil(cache.load(providerID: "codex"))
        try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("codex.json"))
        XCTAssertNil(cache.load(providerID: "codex"))
    }

    func testDoesNotPersistSecretsInNormalizedStrings() throws {
        let (cache, directory) = try cache()
        let secret = "sk-" + String(repeating: "x", count: 48)
        let value = AIUsageSnapshot(providerID: "codex", meters: [
            AIUsageMeter(label: "token=" + secret, used: 1, unit: .credits)
        ], source: "Bearer " + secret)
        try cache.save(value)
        let text = try String(contentsOf: directory.appendingPathComponent("codex.json"), encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
    }

    func testFreshCacheAvoidsFetchAndForcePreservesStaleValueOnFailure() async throws {
        let (cache, _) = try cache()
        let value = snapshot()
        try cache.save(value)
        let client = CacheTestClient()
        let service = AIUsageService(providers: [SymBrainUsageProvider(id: "codex", displayName: "Codex")],
                                     client: client, cache: cache)
        let fresh = await service.usageAll(providerIDs: ["codex"], force: false)
        XCTAssertEqual(fresh.first?.snapshot, value)
        XCTAssertNil(fresh.first?.error)
        XCTAssertEqual(client.calls, 0)
        let failed = await service.usageAll(providerIDs: ["codex"], force: true)
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(client.selection, ["codex"])
        XCTAssertEqual(failed.first?.snapshot, value)
        XCTAssertNotNil(failed.first?.error)
        XCTAssertEqual(service.cachedResults().first?.error, "Last refresh failed")
        _ = await service.usageAll(providerIDs: ["codex"], force: false)
        XCTAssertEqual(client.calls, 2, "A failed refresh must not become a fresh success on the next read")
        service.resetCache()
        XCTAssertTrue(service.cachedResults().isEmpty)
    }

    func testEmptySelectionNeverLaunchesProviderWork() async {
        let client = CacheTestClient()
        let service = AIUsageService(client: client)
        let results = await service.usageAll(providerIDs: [])
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(client.calls, 0)
    }

    func testSelectedCommandAndCredentialReferencesAreRestricted() throws {
        let runner = SelectionTestRunner()
        let client = SymBrainUsageClient(runner: runner, environment: [:], credentialReference: {
            "symvault://usage/" + $0
        })
        _ = try client.fetchReport(providerIDs: ["openrouter", "codex"])
        XCTAssertEqual(runner.arguments, ["usage", "--output", "json", "--providers", "codex,openrouter"])
        XCTAssertEqual(runner.environment["OPENROUTER_API_KEY"], "symvault://usage/openrouter")
        XCTAssertNil(runner.environment["MOONSHOT_API_KEY"])
        XCTAssertNil(runner.environment["KIMI_CODE_API_KEY"])
        XCTAssertThrowsError(try client.fetchReport(providerIDs: ["codex,claude"]))
    }
}

private final class CacheTestClient: SymBrainUsageClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var selected: Set<String> = []
    var calls: Int { lock.withLock { count } }
    var selection: Set<String> { lock.withLock { selected } }
    func fetchReport() throws -> SymBrainUsageReport {
        lock.withLock { count += 1 }
        throw SymBrainUsageError.binaryUnavailable
    }
    func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport {
        lock.withLock { count += 1; selected = providerIDs }
        throw SymBrainUsageError.binaryUnavailable
    }
}

private final class SelectionTestRunner: SymBrainCommandRunner, @unchecked Sendable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        self.arguments = arguments
        self.environment = environment
        return SymBrainCommandResult(standardOutput: Data(#"{"schema_version":1,"providers":[]}"#.utf8),
                                     standardError: Data(), terminationStatus: 0)
    }
}

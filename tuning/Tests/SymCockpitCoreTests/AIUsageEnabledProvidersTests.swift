import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageEnabledProvidersTests: XCTestCase {
    private func suite() throws -> UserDefaults {
        let name = "AIUsageEnabledProvidersTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testNoPersistedSelectionMeansNothingIsEnabled() throws {
        XCTAssertEqual(AIUsageEnabledProviders.load(from: [try suite()]), [])
        XCTAssertEqual(AIUsageEnabledProviders.load(from: []), [])
    }

    func testReadsTheGrandfatheredKeyAndPrefersTheFirstStoreThatHoldsIt() throws {
        XCTAssertEqual(AIUsageEnabledProviders.defaultsKey, "com.symaira.symtune.aiUsage.enabledProviders")
        let empty = try suite(), first = try suite(), second = try suite()
        first.set(["claude"], forKey: AIUsageEnabledProviders.defaultsKey)
        second.set(["codex", "zai"], forKey: AIUsageEnabledProviders.defaultsKey)
        XCTAssertEqual(AIUsageEnabledProviders.load(from: [empty, first, second]), ["claude"])
        XCTAssertEqual(AIUsageEnabledProviders.load(from: [empty, second]), ["codex", "zai"])
        // An explicitly empty selection is a selection: it must not fall through.
        first.set([String](), forKey: AIUsageEnabledProviders.defaultsKey)
        XCTAssertEqual(AIUsageEnabledProviders.load(from: [first, second]), [])
    }

    func testDisabledProviderIsNotServedAndPurgeRemovesItsCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = AIUsageSnapshotCache(directory: directory)
        for id in ["claude", "codex"] {
            try cache.save(AIUsageSnapshot(providerID: id, meters: [
                AIUsageMeter(label: "session", used: 1, limit: 10, unit: .percent)
            ], fetchedAt: Date(), source: "test"))
        }
        let service = AIUsageService(
            providers: [SymBrainUsageProvider(id: "claude", displayName: "Claude"),
                        SymBrainUsageProvider(id: "codex", displayName: "Codex")],
            client: NeverCalledClient(), cache: cache)
        XCTAssertEqual(service.cachedResults(providerIDs: ["claude"]).map(\.providerID), ["claude"])
        XCTAssertEqual(service.cachedResults(providerIDs: []).count, 0)
        service.purgeCache(providerIDs: ["codex"])
        XCTAssertEqual(service.cachedResults().map(\.providerID), ["claude"])
        XCTAssertNil(cache.load(providerID: "codex"))
    }
}

private struct NeverCalledClient: SymBrainUsageClientProtocol {
    func fetchReport() throws -> SymBrainUsageReport { throw SymBrainUsageError.binaryUnavailable }
    func fetchReport(providerIDs: Set<String>) throws -> SymBrainUsageReport { throw SymBrainUsageError.binaryUnavailable }
}

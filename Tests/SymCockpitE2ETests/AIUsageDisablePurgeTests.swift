import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageDisablePurgeTests: XCTestCase {
    @MainActor
    func testDisablingAProviderPurgesOnlyThatProvidersCache() throws {
        let suite = "AIUsageDisablePurgeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        let purged = PurgeRecorder()
        let model = AIUsageViewModel(providers: [], preferences: preferences,
                                     purge: { purged.record($0) }, fetch: { _, _ in [] })
        withExtendedLifetime(model) {
            preferences.setEnabled("claude", true)
            preferences.setEnabled("codex", true)
            XCTAssertTrue(purged.calls.isEmpty, "Enabling must not purge anything")
            preferences.setEnabled("codex", false)
            XCTAssertEqual(purged.calls, [["codex"]])
            preferences.setEnabled("codex", false)
            XCTAssertEqual(purged.calls, [["codex"]], "A no-op disable must not purge again")
            XCTAssertEqual(AIUsageEnabledProviders.load(from: [defaults]), ["claude"])
        }
    }
}

private final class PurgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Set<String>] = []
    var calls: [Set<String>] { lock.withLock { recorded } }
    func record(_ ids: Set<String>) { lock.withLock { recorded.append(ids) } }
}

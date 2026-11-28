import XCTest
import SymCockpitCore
@testable import SymCockpitUI

/// #452: the view model honours failure backoff, provider waits and offline state.
final class AIUsageBackoffRefreshTests: XCTestCase {
    @MainActor
    private func setUp(reply: @escaping @Sendable (String) -> String?) -> (AIUsageViewModel, CallLog) {
        let name = NSTemporaryDirectory() + "AIUsageBackoffRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.refreshInterval = 300
        // Enabled before the model exists, so no selection-change fetch races the test.
        preferences.enabledProviders = ["ok", "bad", "limited"]
        let log = CallLog()
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { selected, _ in
            await log.append(selected)
            return selected.sorted().map { id in
                let error = reply(id)
                return .init(providerID: id, snapshot: error == nil
                    ? AIUsageSnapshot(providerID: id, meters: [], fetchedAt: Date(), source: "fixture") : nil, error: error)
            }
        })
        return (model, log)
    }

    @MainActor
    func testFailingAndRateLimitedProvidersAreSkippedUntilTheirTime() async {
        let (model, log) = setUp { id in
            switch id {
            case "bad": "HTTP 500"
            case "limited": #"AI usage provider "limited" is rate limited; retry in 3600s"#
            default: nil
            }
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        model.now = { clock }
        await log.clear()

        await model.refresh(providerIDs: nil, automatic: true)
        clock = clock.addingTimeInterval(60)
        await model.refresh(providerIDs: nil, automatic: true)
        clock = clock.addingTimeInterval(300)
        await model.refresh(providerIDs: nil, automatic: true)
        await model.refresh() // manual: skips the failure backoff, not the provider's wait
        let calls = await log.calls
        XCTAssertEqual(calls, [["ok", "bad", "limited"], ["ok"], ["ok", "bad"], ["ok", "bad"]])
    }

    @MainActor
    func testOfflineFetchesNothingAndKeepsTheLastUsage() async {
        let (model, log) = setUp { _ in nil }
        await model.refresh()
        XCTAssertEqual(model.rows.count, 3)
        await log.clear()
        model.isOnline = { false }
        await model.refresh()
        let calls = await log.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertTrue(model.rows.allSatisfy { $0.error == nil }, "offline is not a provider failure")
    }
}

private actor CallLog {
    private(set) var calls: [Set<String>] = []
    func append(_ selected: Set<String>) { calls.append(selected) }
    func clear() { calls = [] }
}

import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageQueuedRefreshTests: XCTestCase {
    @MainActor
    func testPerProviderRefreshDuringAnotherRefreshIsQueuedNotDropped() async throws {
        let suite = "AIUsageQueuedRefreshTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["p", "q"]
        let gate = QueuedFetchGate()
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { selected, _ in
            await gate.fetch(selected)
        })
        defer { model.stop() }
        // Let any refresh scheduled by the preference change settle first.
        for _ in 0..<20 { await Task.yield() }
        await gate.reset()

        let running = Task { await model.refresh() }
        try await gate.waitUntilStarted(1)
        XCTAssertTrue(model.isRefreshing)
        await model.refresh(providerID: "q") // Arrives mid-flight: must not be dropped.
        await model.refresh(providerID: "q") // Coalesces with the queued one.
        let callsWhileBusy = await gate.calls
        XCTAssertEqual(callsWhileBusy, [["p", "q"]])

        await gate.release()
        await running.value
        try await gate.waitUntilStarted(2)
        await gate.release()
        for _ in 0..<50 { await Task.yield() }
        let calls = await gate.calls
        XCTAssertEqual(calls, [["p", "q"], ["q"]])
    }
}

private actor QueuedFetchGate {
    private(set) var calls: [Set<String>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = 0

    func reset() { calls = []; waiters = []; released = 0 }

    func fetch(_ selected: Set<String>) async -> [AIUsageService.ProviderResult] {
        calls.append(selected)
        if released == 0 {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            released -= 1
        }
        return selected.sorted().map { .init(providerID: $0, snapshot: nil, error: "fixture") }
    }

    func release() {
        if waiters.isEmpty { released += 1 } else { waiters.removeFirst().resume() }
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while calls.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(calls.count, count)
    }
}

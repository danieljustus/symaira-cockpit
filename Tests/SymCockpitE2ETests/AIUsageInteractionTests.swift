import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageInteractionTests: XCTestCase {
    @MainActor
    private func preferences() -> AIUsagePreferences {
        let name = "AIUsageInteractionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AIUsagePreferences(defaults: defaults)
    }

    @MainActor
    func testProductionDisplayToggleActionsPersist() async throws {
        _ = NSApplication.shared
        let name = "AIUsageControls.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AIUsagePreferences(defaults: defaults)
        let menu = NSHostingMenu(rootView: AIUsageDisplayControls(preferences: preferences))
        menu.update()
        let remaining = try XCTUnwrap(menu.items.firstIndex { $0.title == "Remaining values (off: used)" })
        menu.performActionForItem(at: remaining)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(preferences.layout.remaining)
        menu.update()
        let bars = try XCTUnwrap(menu.items.firstIndex { $0.title == "Menu-bar mini-bars (off: text)" })
        menu.performActionForItem(at: bars)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(preferences.layout.bars)
        menu.update()
        let reset = try XCTUnwrap(menu.items.firstIndex { $0.title == "Exact reset time (off: countdown)" })
        menu.performActionForItem(at: reset)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(preferences.layout.absoluteReset)
        preferences.layout.expanded = ["p"]
        preferences.layout.onDemand = ["metric"]
        preferences.layout.hidden = ["hidden"]
        preferences.layout.pins = ["p": ["metric"]]
        preferences.layout.metricOrder = ["p": ["metric", "hidden"]]
        preferences.displayOrder = ["q", "p"]
        let reloaded = AIUsagePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(reloaded.layout, preferences.layout)
        XCTAssertEqual(reloaded.displayOrder, ["q", "p"])
    }

    @MainActor
    func testLivePreferencesChangeWithoutFetchAndStaleTimestamp() async {
        let preferences = preferences()
        preferences.enabledProviders = ["p"]
        preferences.menuBarEnabled = true
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { _, _ in
            XCTFail("Presentation must never fetch")
            return []
        })
        let date = Date(timeIntervalSince1970: 1234)
        let snapshot = AIUsageSnapshot(providerID: "p", meters: [
            .init(label: "Weekly", used: 25, unit: .percent),
            .init(label: "Missing", limit: 100, unit: .requests),
            .init(label: "Spend", used: 3, unit: .currency("USD"))
        ], fetchedAt: date, source: "test fixture")
        model.apply([.init(providerID: "p", snapshot: snapshot, error: "Unavailable")])
        let metrics = model.metrics(for: model.rows[0])
        preferences.layout.togglePin(metrics[0].id, provider: "p")
        preferences.layout.togglePin(metrics[1].id, provider: "p")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.statusPins.count, 1)
        XCTAssertEqual(model.statusPins.first?.value, "75%")
        XCTAssertTrue(model.statusItemText.contains("stale"))
        XCTAssertEqual(model.rows.first?.lastSuccessAt, date)
        XCTAssertEqual(model.rows.first?.snapshot?.fetchedAt, date)
        preferences.layout.remaining = false
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.statusPins.first?.value, "25%")
        preferences.layout.hidden.insert(metrics[0].id)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.statusPins.isEmpty)
        preferences.layout.hidden.remove(metrics[0].id)
        preferences.setVisibility("p", visible: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertTrue(model.statusPins.isEmpty)
    }

    @MainActor
    func testProviderAndMetricOrderingAndOnDemand() {
        let preferences = preferences()
        preferences.enabledProviders = ["p", "q"]
        let model = AIUsageViewModel(providers: [UsageFixtureProvider(id: "p"), UsageFixtureProvider(id: "q")],
            preferences: preferences, fetch: { _, _ in [] })
        model.apply(["p", "q"].map { id in
            .init(providerID: id, snapshot: .init(providerID: id, meters: [
                .init(label: "Weekly", used: 20, unit: .percent),
                .init(label: "Session", used: 30, unit: .percent)
            ], source: "test fixture"), error: nil)
        })
        model.moveProvider("q", before: "p")
        XCTAssertEqual(model.visibleRows.map(\.id), ["q", "p"])
        let row = model.rows[0]
        let metrics = model.metrics(for: row)
        preferences.layout.onDemand.insert(metrics[0].id)
        model.moveMetric(metrics[1].id, before: metrics[0].id, row: row)
        XCTAssertEqual(model.metrics(for: row).map(\.id), [metrics[1].id, metrics[0].id])
        XCTAssertTrue(preferences.layout.onDemand.contains(metrics[1].id))
        preferences.layout.expanded.insert("p")
        XCTAssertTrue(preferences.layout.expanded.contains("p"))
    }

    @MainActor
    func testCustomizeAndStarActivateInMountedProductionCard() async throws {
        _ = NSApplication.shared
        let preferences = preferences()
        preferences.enabledProviders = ["p"]
        let model = AIUsageViewModel(providers: [UsageFixtureProvider(id: "p")], preferences: preferences,
            fetch: { _, _ in XCTFail("Passive interaction host must not fetch"); return [] })
        model.apply([.init(providerID: "p", snapshot: .init(providerID: "p", meters: [
            .init(label: "Weekly", used: 25, unit: .percent)
        ], source: "fixture"), error: nil)])
        let view = AIUsageCardView(model: model).padding().environment(\.accessibilityEnabled, true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 600))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        try press("Customize…", in: window)
        try await Task.sleep(for: .milliseconds(100))
        try press("Metrics…", in: window)
        try await Task.sleep(for: .milliseconds(100))
        try press("Star", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(preferences.layout.pins["p"]?.count, 1)
        try press("Unstar", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(preferences.layout.pins["p"], [])
        try press("On demand", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(preferences.layout.onDemand.count, 1)
        try press("Enabled", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(preferences.layout.hidden.count, 1)
        try press("Enabled", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(preferences.layout.hidden.isEmpty)
        try press("Done", in: window)
        try await Task.sleep(for: .milliseconds(100))
        try press("Show on-demand metrics", in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(preferences.layout.expanded.contains("p"))
    }

    @MainActor
    private func press(_ label: String, in window: NSWindow) throws {
        var seen: Set<ObjectIdentifier> = []
        func elements(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            var children = node.responds(to: selector)
                ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return children.flatMap(elements) + [node]
        }
        let nodes = elements(window)
        let button = try XCTUnwrap(nodes.first { node in
            let selector = NSSelectorFromString("accessibilityLabel")
            return node.responds(to: selector)
                && node.perform(selector)?.takeUnretainedValue() as? String == label
                && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }, "Missing control: \(label)")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(button.method(for: selector), to: Action.self)
        XCTAssertTrue(action(button, selector))
    }

    @MainActor
    func testCachedLaunchKeepsSourceDateWithoutFreshHistory() {
        let preferences = preferences()
        preferences.enabledProviders = ["p"]
        let date = Date(timeIntervalSince1970: 1234)
        let snapshot = AIUsageSnapshot(providerID: "p", meters: [.init(label: "Weekly", used: 25, unit: .percent)],
            fetchedAt: date, source: "fixture")
        let model = AIUsageViewModel(providers: [], preferences: preferences,
            cached: { selected in
                XCTAssertEqual(selected, ["p"])
                return [.init(providerID: "p", snapshot: snapshot, error: nil)]
            }, fetch: { _, _ in XCTFail("Stopped before asynchronous refresh"); return [] })
        model.start()
        XCTAssertEqual(model.rows.first?.snapshot?.fetchedAt, date)
        XCTAssertEqual(model.rows.first?.lastSuccessAt, date)
        XCTAssertEqual(model.rows.first?.isStale, true)
        XCTAssertEqual(model.rows.first?.history.count, 0)
        model.stop()
    }

    @MainActor
    func testSelectiveRefreshKeepsOtherProviderAndAllOffDoesNotFetch() async {
        let preferences = preferences()
        preferences.enabledProviders = ["p", "q"]
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { selected, force in
            XCTAssertEqual(selected, ["p"])
            XCTAssertTrue(force)
            return [.init(providerID: "p", snapshot: nil, error: "Unavailable")]
        })
        model.apply([.init(providerID: "q", snapshot: .init(providerID: "q", meters: [], source: "fixture"), error: nil)])
        await model.refresh(providerID: "p")
        XCTAssertEqual(Set(model.rows.map(\.id)), ["p", "q"])
        preferences.enabledProviders = []
        await model.refresh()
        XCTAssertTrue(model.rows.isEmpty)
    }

    @MainActor
    func testDisableDuringFetchCannotRepublishSnapshot() async {
        let preferences = preferences()
        preferences.enabledProviders = ["p"]
        let gate = UsageFetchGate()
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { _, _ in await gate.fetch() })
        let task = Task { await model.refresh() }
        for _ in 0..<1000 {
            if await gate.started { break }
            await Task.yield()
        }
        let started = await gate.started
        XCTAssertTrue(started)
        preferences.enabledProviders = []
        await gate.finish()
        await task.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.statusPins.isEmpty)
    }

    @MainActor
    func testMiniBarsAreImageAttachmentsAndUnboundedPinsOmitted() throws {
        let pins = [AIUsagePin(label: "Weekly", value: "75%", fraction: 0.75, stale: true)]
        let title = StatusBarController.aiMiniBars(pins)
        var attachments: [NSTextAttachment] = []
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
        }
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.image?.size, NSSize(width: 10, height: 16))
        XCTAssertNotNil(attachment.image?.tiffRepresentation)
        XCTAssertTrue(title.string.contains("stale"))
        XCTAssertEqual(StatusBarController.aiMiniBars([
            .init(label: "Spend", value: "3 USD", fraction: nil, stale: false)
        ]).length, 0)
    }
}

private struct UsageFixtureProvider: AIUsageProvider {
    let id: String
    var displayName: String { id }
    var isConfigured: Bool { true }
    var authState: ExternalAuthState { .init(status: .available, detail: "Fixture", source: "test") }
}

private actor UsageFetchGate {
    private var continuation: CheckedContinuation<[AIUsageService.ProviderResult], Never>?
    var started: Bool { continuation != nil }
    func fetch() async -> [AIUsageService.ProviderResult] {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: [.init(providerID: "p", snapshot: .init(providerID: "p",
            meters: [.init(label: "Weekly", used: 25, unit: .percent)], source: "fixture"), error: nil)])
        continuation = nil
    }
}

import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageLocalRecordedSpendUITests: XCTestCase {
    private func history(_ status: String = "available", zero: Bool = false) throws -> AIUsageRecordedHistory {
        let report = try JSONDecoder().decode(SymBrainUsageReport.self, from: Data(AIUsageRecordedHistoryUITests.fixture.utf8))
        let original = try XCTUnwrap(report.providers.first?.history)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["status"] = status
        object["excluded_events"] = status == "partial" ? 2 : 0
        if ["no_data", "unavailable"].contains(status) { object["daily"] = []; object["periods"] = [] }
        var data = try JSONSerialization.data(withJSONObject: object)
        if zero {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
                .replacingOccurrences(of: "\"42\"", with: "\"0\"")
                .replacingOccurrences(of: "0.0000000001", with: "0")
            data = Data(text.utf8)
        }
        return try JSONDecoder().decode(AIUsageRecordedHistory.self, from: data)
    }

    @MainActor
    func testConsentPersistenceRevocationAndHiddenCardsDoNotChangeTotal() async throws {
        let suite = "LocalSpendConsent." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        XCTAssertFalse(preferences.opencodeHistoryEnabled)
        preferences.enabledProviders = ["grok", "opencode"]
        preferences.grokHistoryEnabled = true
        preferences.opencodeHistoryEnabled = true
        preferences.localSpendPeriod = .last30Days
        preferences.localSpendMode = .tokens
        let restored = AIUsagePreferences(defaults: defaults)
        XCTAssertTrue(restored.opencodeHistoryEnabled)
        XCTAssertTrue(restored.grokHistoryEnabled)
        XCTAssertEqual(restored.localSpendPeriod, .last30Days)
        XCTAssertEqual(restored.localSpendMode, .tokens)
        let fixture = try history()
        let recorder = LocalSpendUIRecorder(history: fixture)
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences,
            fetchHistory: { await recorder.fetch($0, grok: $2, opencode: $3) }, fetch: { _, _ in [] })
        await model.refresh(force: false)
        XCTAssertEqual(model.localRecordedSpend.total, 84)
        XCTAssertEqual(model.rows.filter { $0.snapshot == nil && $0.recordedHistory != nil }.count, 2)
        preferences.displayVisibility = ["grok": false, "opencode": false]
        XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertEqual(model.localRecordedSpend.total, 84)
        preferences.opencodeHistoryEnabled = false
        XCTAssertNil(model.rows.first { $0.id == "opencode" }?.recordedHistory)
        XCTAssertEqual(model.localRecordedSpend.total, 42)
        await model.refresh(providerID: "grok")
        let scoped = await recorder.last
        XCTAssertFalse(scoped.opencode)
        XCTAssertTrue(scoped.grok)
        preferences.setEnabled("grok", false)
        XCTAssertNil(model.localRecordedSpend.total)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        preferences.opencodeHistoryEnabled = true
        for _ in 0..<100 { await Task.yield() }
        await model.refresh(force: false)
        XCTAssertEqual(model.localRecordedSpend.total, 42)
        preferences.setEnabled("opencode", false)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        XCTAssertTrue(preferences.opencodeHistoryEnabled, "Selection does not erase persisted consent")
        model.stop()
    }

    @MainActor
    func testPassiveNativeSharedPanelRendersStatesInBothAppearancesAndWidths() throws {
        let suite = "LocalSpendRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences,
            fetch: { _, _ in XCTFail("Passive host must not fetch"); return [] })
        defer { model.stop() }
        for status in ["available", "partial", "no_data", "unavailable", "absent", "zero", "all_disabled"] {
            preferences.enabledProviders = status == "all_disabled" ? [] : ["grok", "opencode"]
            preferences.grokHistoryEnabled = true
            preferences.opencodeHistoryEnabled = true
            let fixture = try history(["zero", "absent", "all_disabled"].contains(status) ? "available" : status, zero: status == "zero")
            model.apply([.init(providerID: "grok", snapshot: nil, error: "fixture quota unavailable", history: fixture),
                         .init(providerID: "opencode", snapshot: nil, error: "fixture quota unavailable", history: status == "absent" ? nil : fixture)])
            for width in [CGFloat(300), CGFloat(620)] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let view = NSHostingView(rootView: VStack(alignment: .leading) {
                        Text("Example — Synthetic Local Recorded Spend")
                        AIUsageCardView(model: model)
                    }.padding().frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                    view.appearance = NSAppearance(named: appearance)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
                    if let output = ProcessInfo.processInfo.environment["LOCAL_SPEND_FIXTURE_EVIDENCE"] {
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: output).appendingPathComponent("local-spend-\(status)-\(Int(width))-\(name).png"))
                    }
                }
            }
        }
    }

    @MainActor
    func testNativeAXPeriodModeActionsAndOpenCodeModelDisclosure() async throws {
        _ = NSApplication.shared
        let suite = "LocalSpendAX." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["opencode"]
        preferences.opencodeHistoryEnabled = true
        let fixture = try history()
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences, fetch: { _, _ in [] })
        model.apply([.init(providerID: "opencode", snapshot: nil, error: "quota unavailable", history: fixture)])
        let view = VStack(alignment: .leading) {
            Text("Example — Synthetic OpenCode History")
            AIUsageHistoryConsent(preferences: preferences)
            AIUsageCardView(model: model)
        }.padding().frame(width: 620).environment(\.accessibilityEnabled, true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 1200))
        window.orderFront(nil)
        defer { window.close(); model.stop() }
        try await Task.sleep(for: .milliseconds(100))
        func nodes() -> [NSObject] {
            var seen: Set<ObjectIdentifier> = []
            func walk(_ node: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                let selector = NSSelectorFromString("accessibilityChildren")
                var children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
                return [node] + children.flatMap(walk)
            }
            return walk(window)
        }
        func attribute(_ node: NSObject, _ name: String) -> String {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() else { return "" }
            return String(describing: value)
        }
        func press(_ label: String) throws {
            let node = try XCTUnwrap(nodes().first { attribute($0, "accessibilityLabel") == label })
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(node.responds(to: selector))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let action = unsafeBitCast(node.method(for: selector), to: Action.self)
            XCTAssertTrue(action(node, selector))
        }
        try press("Yesterday")
        XCTAssertEqual(preferences.localSpendPeriod, .yesterday)
        XCTAssertNil(model.localRecordedSpend.total)
        try press("30 Days")
        try press("Tokens")
        XCTAssertEqual(model.localRecordedSpend.total, 42)
        try press("Cost / 1M")
        XCTAssertNotNil(model.localRecordedSpend.total)
        try press("Today Models (1)")
        try await Task.sleep(for: .milliseconds(100))
        let evidence = nodes().map { node in
            ["accessibilityLabel", "accessibilityValue", "accessibilityRole"].map { attribute(node, $0) }.joined(separator: " | ")
        }
        XCTAssertTrue(evidence.contains { $0.contains("0.0000000001 USD recorded") && $0.contains("42 tokens") })
        let restored = AIUsagePreferences(defaults: defaults)
        XCTAssertEqual(restored.localSpendPeriod, .last30Days)
        XCTAssertEqual(restored.localSpendMode, .costPerMillion)
        try press("Read local OpenCode session usage, unattributed")
        XCTAssertFalse(preferences.opencodeHistoryEnabled)
        XCTAssertNil(model.rows.first?.recordedHistory)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        XCTAssertFalse(AIUsagePreferences(defaults: defaults).opencodeHistoryEnabled)
        XCTAssertFalse(preferences.grokHistoryEnabled, "OpenCode consent never changes Grok consent")
        if let output = ProcessInfo.processInfo.environment["LOCAL_SPEND_FIXTURE_EVIDENCE"] {
            try evidence.joined(separator: "\n").write(toFile: output + "/local-spend-native-ax.txt", atomically: true, encoding: .utf8)
        }
    }
}

private actor LocalSpendUIRecorder {
    let history: AIUsageRecordedHistory
    var last = (grok: false, opencode: false)
    init(history: AIUsageRecordedHistory) { self.history = history }
    func fetch(_ selection: Set<String>, grok: Bool, opencode: Bool) -> [AIUsageService.ProviderResult] {
        last = (grok, opencode)
        return selection.sorted().map { .init(providerID: $0, snapshot: nil, error: "fixture quota unavailable",
            history: ($0 == "grok" && grok) || ($0 == "opencode" && opencode) ? history : nil) }
    }
}

import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageClaudeHistoryUITests: XCTestCase {
    private static let snapshot = "openusage:abf472d5dbb23645c3afbb5a0c7429606ffbdcd7:litellm-2026-07-02:supplement-2026-10-16:modelsdev-2026-07-02"

    private func history(_ basis: String = "mixed", partial: Bool = false) throws -> AIUsageRecordedHistory {
        let recorded = ["recorded", "mixed"].contains(basis) ? 1 : 0
        let estimated = ["estimated", "mixed"].contains(basis) ? 1 : 0
        let missing = partial || basis == "unknown" ? 1 : 0
        var row: [String: Any] = ["model": "claude-sonnet-4-5", "events": recorded + estimated + missing,
            "tokens": "100", "missing_tokens": 0, "missing_cost": missing,
            "recorded_events": recorded, "estimated_events": estimated, "cost_basis": basis]
        if recorded > 0 { row["recorded_cost"] = "0.2" }
        if estimated > 0 { row["estimated_cost"] = "0.1000000001" }
        let wire: [String: Any] = ["scope": "local_machine", "attribution": "unattributed", "currency": "USD",
            "cost_basis": basis, "price_snapshot": Self.snapshot, "timezone": "local",
            "status": missing > 0 ? "partial" : "available", "excluded_events": 0,
            "daily": [["key": "2026-10-25", "models": [row]]],
            "periods": [["key": "today", "models": [row]], ["key": "last_30_days", "models": [row]]]]
        return try JSONDecoder().decode(AIUsageRecordedHistory.self, from: JSONSerialization.data(withJSONObject: wire))
    }

    @MainActor
    private func defaults(_ name: String) throws -> UserDefaults {
        let base = ProcessInfo.processInfo.environment["CLAUDE_HISTORY_UI_DEFAULTS"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("claude-history-ui-defaults").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let path = base + "/" + name + "-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: path))
        defaults.set("Example isolation sentinel", forKey: "isolation-sentinel")
        XCTAssertTrue(defaults.synchronize())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".plist"), "Absolute-path suite must be file isolated")
        addTeardownBlock { defaults.removePersistentDomain(forName: path) }
        return defaults
    }

    @MainActor
    func testClaudeConsentDefaultsScopedFlagsRevocationAndQuotaIndependence() async throws {
        let defaults = try defaults("consent")
        let preferences = AIUsagePreferences(defaults: defaults)
        XCTAssertFalse(preferences.claudeHistoryEnabled)
        XCTAssertFalse(preferences.claudeHistoryOnly)
        let fixture = try history()
        let calls = ClaudeUIRequests(history: fixture)
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences,
            fetchClaudeHistory: { await calls.fetch($0, grok: $2, opencode: $3, claude: $4, only: $5) }, fetch: { _, _ in [] })
        preferences.enabledProviders = ["claude", "grok"]
        preferences.claudeHistoryOnly = true
        await settle(model)
        var flags = await calls.last
        XCTAssertFalse(flags.claude)
        XCTAssertFalse(flags.only)
        preferences.claudeHistoryEnabled = true
        await settle(model)
        flags = await calls.last
        XCTAssertTrue(flags.claude)
        XCTAssertTrue(flags.only)
        XCTAssertFalse(flags.grok)
        XCTAssertFalse(flags.opencode)
        XCTAssertNotNil(model.rows.first { $0.id == "claude" }?.error)
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.3000000001"))
        preferences.displayVisibility = ["claude": false]
        XCTAssertEqual(model.localRecordedSpend.total, Decimal(string: "0.3000000001"))
        await model.refresh(providerID: "grok")
        flags = await calls.last
        XCTAssertFalse(flags.claude)
        XCTAssertFalse(flags.only)
        preferences.claudeHistoryEnabled = false
        XCTAssertNil(model.rows.first { $0.id == "claude" }?.recordedHistory)
        XCTAssertNil(model.localRecordedSpend.total)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        let restored = AIUsagePreferences(defaults: defaults)
        XCTAssertFalse(restored.claudeHistoryEnabled)
        XCTAssertTrue(restored.claudeHistoryOnly, "History-only choice never enables history or changes quota consent by itself")
        XCTAssertFalse(preferences.grokHistoryEnabled)
        model.stop()
    }

    @MainActor
    private func settle(_ model: AIUsageViewModel) async {
        for _ in 0..<100 { await Task.yield() }
        await model.refresh(force: false)
    }

    @MainActor
    func testPassiveClaudeSharedCardsLightDarkCompactWideAndPartialStates() throws {
        let preferences = AIUsagePreferences(defaults: try defaults("renders"))
        preferences.enabledProviders = ["claude"]
        preferences.claudeHistoryEnabled = true
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences,
                                    fetch: { _, _ in XCTFail("Passive host must not fetch"); return [] })
        model.stop()
        for state in ["recorded", "estimated", "mixed", "unknown", "partial", "invalid", "off"] {
            preferences.claudeHistoryEnabled = state != "off"
            let fixture = try history(["partial", "invalid", "off"].contains(state) ? "mixed" : state, partial: state == "partial")
            model.apply([.init(providerID: "claude", snapshot: nil, error: "Example quota unavailable",
                               history: state == "invalid" ? nil : fixture)])
            for width in [CGFloat(300), CGFloat(620)] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let host = NSHostingView(rootView: VStack(alignment: .leading) {
                        Text("Example — Synthetic Claude History, Not Live Data")
                        AIUsageCardView(model: model)
                    }.padding().frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                    if let output = ProcessInfo.processInfo.environment["CLAUDE_HISTORY_UI_EVIDENCE"] {
                        let url = URL(fileURLWithPath: output).appendingPathComponent("claude-\(state)-\(Int(width))-\(name).png")
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                    }
                }
            }
        }
    }

    @MainActor
    func testNativeClaudeAXCoverageProvenanceAndConsentControls() async throws {
        _ = NSApplication.shared
        let preferences = AIUsagePreferences(defaults: try defaults("AX"))
        preferences.enabledProviders = ["claude"]
        preferences.claudeHistoryEnabled = true
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences, fetch: { _, _ in [] })
        model.stop()
        model.apply([.init(providerID: "claude", snapshot: nil, error: "Example quota unavailable", history: try history())])
        let root = VStack(alignment: .leading) {
            Text("Example — Synthetic Claude History")
            AIUsageHistoryConsent(preferences: preferences)
            AIUsageCardView(model: model)
        }.padding().frame(width: 620).environment(\.accessibilityEnabled, true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 1600))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func nodes() -> [NSObject] {
            var seen: Set<ObjectIdentifier> = []
            func walk(_ node: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                let selector = NSSelectorFromString("accessibilityChildren")
                var children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
                return children.flatMap(walk) + [node]
            }
            return walk(window)
        }
        func attribute(_ node: NSObject, _ name: String) -> String {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector), let raw = node.perform(selector)?.takeUnretainedValue() else { return "" }
            return (raw as? NSAttributedString)?.string ?? String(describing: raw)
        }
        func press(_ label: String) throws {
            let node = try XCTUnwrap(nodes().first { attribute($0, "accessibilityLabel") == label })
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(node.responds(to: selector))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Action.self)(node, selector))
        }
        try press("Today Models (1)")
        try press("Frozen Price Provenance")
        try await Task.sleep(for: .milliseconds(100))
        let evidence = nodes().map { node in
            ["accessibilityLabel", "accessibilityValue", "accessibilityRole"].map { attribute(node, $0) }.joined(separator: " | ")
        }
        XCTAssertTrue(evidence.contains { $0.contains("0.2 USD recorded") && $0.contains("0.1000000001 USD estimated") })
        XCTAssertTrue(evidence.contains { $0.contains("1 recorded / 1 estimated events") })
        XCTAssertTrue(evidence.contains { $0.contains(Self.snapshot) })
        XCTAssertTrue(evidence.contains { $0.contains("Includes Estimates") || $0.contains("includes estimates") })
        try press("Claude history only, skip Claude quota credentials and requests")
        XCTAssertTrue(preferences.claudeHistoryOnly)
        XCTAssertTrue(preferences.claudeHistoryEnabled)
        try press("Read local Claude session usage, unattributed")
        XCTAssertFalse(preferences.claudeHistoryEnabled)
        XCTAssertNil(model.rows.first?.recordedHistory)
        XCTAssertTrue(model.localRecordedSpend.contributions.isEmpty)
        if let output = ProcessInfo.processInfo.environment["CLAUDE_HISTORY_UI_EVIDENCE"] {
            try evidence.joined(separator: "\n").write(toFile: output + "/claude-native-ax.txt", atomically: true, encoding: .utf8)
        }
    }
}

private actor ClaudeUIRequests {
    let history: AIUsageRecordedHistory
    var last = (grok: false, opencode: false, claude: false, only: false)
    init(history: AIUsageRecordedHistory) { self.history = history }
    func fetch(_ selection: Set<String>, grok: Bool, opencode: Bool, claude: Bool, only: Bool) -> [AIUsageService.ProviderResult] {
        last = (grok, opencode, claude, only)
        return selection.sorted().map { .init(providerID: $0, snapshot: nil, error: "Example quota unavailable",
                                              history: $0 == "claude" && claude ? history : nil) }
    }
}

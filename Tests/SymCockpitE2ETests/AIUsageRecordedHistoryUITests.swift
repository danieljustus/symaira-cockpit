import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageRecordedHistoryUITests: XCTestCase {
    static let fixture = #"""
    {
      "schema_version": 1,
      "providers": [
        {
          "id": "grok",
          "display_name": "Grok",
          "configured": false,
          "auth_status": {
            "status": "missing",
            "detail": "fixture"
          },
          "error": "quota unavailable",
          "history": {
            "scope": "local_machine",
            "attribution": "unattributed",
            "currency": "USD",
            "cost_basis": "recorded",
            "timezone": "local",
            "status": "available",
            "excluded_events": 0,
            "daily": [
              {
                "key": "2026-10-25",
                "models": [
                  {
                    "model": "grok-4",
                    "events": 1,
                    "missing_tokens": 0,
                    "missing_cost": 0,
                    "tokens": "42",
                    "recorded_cost": "0.0000000001"
                  }
                ]
              }
            ],
            "periods": [
              {
                "key": "last_30_days",
                "models": [
                  {
                    "model": "grok-4",
                    "events": 1,
                    "missing_tokens": 0,
                    "missing_cost": 0,
                    "tokens": "42",
                    "recorded_cost": "0.0000000001"
                  }
                ]
              },
              {
                "key": "today",
                "models": [
                  {
                    "model": "grok-4",
                    "events": 1,
                    "missing_tokens": 0,
                    "missing_cost": 0,
                    "tokens": "42",
                    "recorded_cost": "0.0000000001"
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """#

    @MainActor
    func testDecodedHistoryReachesMountedSharedCardWithoutQuota() throws {
        let suite = "GrokHistoryFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        XCTAssertFalse(preferences.grokHistoryEnabled)
        preferences.enabledProviders = ["grok"]
        preferences.grokHistoryEnabled = true
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences, fetch: { _, _ in [] })
        let history = try XCTUnwrap(JSONDecoder().decode(SymBrainUsageReport.self, from: Data(Self.fixture.utf8)).providers.first?.history)
        model.apply([.init(providerID: "grok", snapshot: nil, error: "not configured", history: history)])
        XCTAssertEqual(model.visibleRows.first?.recordedHistory?.periods.first?.models.first?.tokens, "42")
        for status in ["available", "partial", "no_data", "unavailable"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
            object["status"] = status
            object["excluded_events"] = status == "partial" ? 2 : 0
            if status == "no_data" || status == "unavailable" { object["daily"] = []; object["periods"] = [] }
            let variant = try JSONDecoder().decode(AIUsageRecordedHistory.self,
                from: JSONSerialization.data(withJSONObject: object))
            model.apply([.init(providerID: "grok", snapshot: nil, error: "not configured", history: variant)])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: VStack(alignment: .leading) {
                Text("Example — Synthetic Grok History Fixture")
                AIUsageCardView(model: model)
            }.padding().frame(width: 620).background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
            if let output = ProcessInfo.processInfo.environment["GROK_FIXTURE_EVIDENCE"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output)
                    .appendingPathComponent("history-\(status)-\(name).png"))
            }
            }
        }
        preferences.grokHistoryEnabled = false
        XCTAssertNil(model.rows.first?.recordedHistory)
        model.stop()
    }

    @MainActor
    func testNativeHistoryDisclosureAXActionRevealsExactModelData() async throws {
        _ = NSApplication.shared
        let history = try XCTUnwrap(JSONDecoder().decode(SymBrainUsageReport.self, from: Data(Self.fixture.utf8)).providers.first?.history)
        let view = VStack(alignment: .leading) {
            Text("Example — Synthetic Grok History Fixture")
            AIUsageRecordedHistoryView(history: history, providerName: "Grok")
        }.padding().frame(width: 620).environment(\.accessibilityEnabled, true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 900))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        var seen: Set<ObjectIdentifier> = []
        func elements(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            var children = node.responds(to: selector)
                ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap(elements)
        }
        func label(_ node: NSObject) -> String? {
            let selector = NSSelectorFromString("accessibilityLabel")
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
        }
        let nodes = elements(window)
        let disclosure = try XCTUnwrap(nodes.first { label($0) == "Today Models (1)" })
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(disclosure.responds(to: selector))
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(disclosure.method(for: selector), to: Action.self)
        XCTAssertTrue(action(disclosure, selector))
        try await Task.sleep(for: .milliseconds(100))
        seen = []
        let expanded = elements(window)
        let descriptions = expanded.map { node in
            ["accessibilityLabel", "accessibilityValue", "accessibilityRole"].compactMap { name -> String? in
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() else { return nil }
                return String(describing: value)
            }.joined(separator: " | ")
        }
        if let output = ProcessInfo.processInfo.environment["GROK_FIXTURE_EVIDENCE"] {
            try descriptions.joined(separator: "\n").write(toFile: output + "/history-native-ax.txt", atomically: true, encoding: .utf8)
        }
        let detail = try XCTUnwrap(descriptions.first { $0.contains("grok-4:") })
        XCTAssertTrue(detail.contains("0.0000000001 USD recorded"))
        XCTAssertTrue(detail.contains("42 tokens"))
        XCTAssertTrue(detail.contains("0 missing cost"))
    }

    @MainActor
    func testConsentAndSelectionFlowClearHistoryAndRefreshWithScopedOptIn() async throws {
        let suite = "GrokHistoryFlow." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["grok", "codex"]
        let history = try XCTUnwrap(JSONDecoder().decode(SymBrainUsageReport.self, from: Data(Self.fixture.utf8)).providers.first?.history)
        let recorder = HistoryUIRecorder(history: history)
        let model = AIUsageViewModel(providers: SymBrainUsageProvider.catalog(), preferences: preferences,
            fetchHistory: { selection, force, grok, _ in await recorder.fetch(selection, force: force, consent: grok) },
            fetch: { _, _ in XCTFail("Use scoped history fetch"); return [] })
        let initialCalls = await recorder.calls
        XCTAssertEqual(initialCalls, 0)
        await model.refresh(force: false)
        XCTAssertNil(model.rows.first { $0.id == "grok" }?.recordedHistory)
        preferences.grokHistoryEnabled = true
        for _ in 0..<100 { await Task.yield() }
        await model.refresh(force: false)
        XCTAssertNotNil(model.rows.first { $0.id == "grok" }?.recordedHistory)
        XCTAssertTrue(AIUsagePreferences(defaults: defaults).grokHistoryEnabled)
        await model.refresh(providerID: "codex")
        let lastConsent = await recorder.lastConsent
        let lastSelection = await recorder.lastSelection
        XCTAssertFalse(lastConsent)
        XCTAssertEqual(lastSelection, ["codex"])
        XCTAssertNotNil(model.rows.first { $0.id == "grok" }?.recordedHistory)
        preferences.grokHistoryEnabled = false
        XCTAssertNil(model.rows.first { $0.id == "grok" }?.recordedHistory, "Revocation clears synchronously, not on the next scan")
        preferences.grokHistoryEnabled = true
        for _ in 0..<100 { await Task.yield() }
        preferences.setEnabled("grok", false)
        XCTAssertFalse(model.rows.contains { $0.id == "grok" })
        await model.refresh()
        let disabledConsent = await recorder.lastConsent
        XCTAssertFalse(disabledConsent)
        model.stop()
    }
}

private actor HistoryUIRecorder {
    let history: AIUsageRecordedHistory
    var calls = 0
    var lastSelection: Set<String> = []
    var lastConsent = false
    init(history: AIUsageRecordedHistory) { self.history = history }
    func fetch(_ selection: Set<String>, force: Bool, consent: Bool) -> [AIUsageService.ProviderResult] {
        calls += 1
        lastSelection = selection
        lastConsent = consent
        return selection.sorted().map { .init(providerID: $0, snapshot: nil, error: "fixture quota unavailable",
            history: $0 == "grok" && consent ? history : nil) }
    }
}

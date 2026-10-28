import AppKit
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageCustomizationTests: XCTestCase {
    @MainActor
    func testUndoAndProviderResetPreserveConsentCredentialsAndOtherProviders() throws {
        let suite = "AIUsageCustomizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["codex", "claude"]
        preferences.setVaultEntryPath("existing/reference", for: "openrouter")
        let codex = AIUsageMetric.metrics(provider: "codex", meters: [.init(label: "Session", used: 25, unit: .percent)])[0]
        let claude = AIUsageMetric.metrics(provider: "claude", meters: [.init(label: "Session", used: 50, unit: .percent)])[0]
        preferences.layout.togglePin(codex.id, provider: "codex")
        preferences.layout.togglePin(claude.id, provider: "claude")
        let before = preferences.layout
        preferences.undoManager.removeAllActions()
        preferences.layout.hidden.insert(codex.id)
        XCTAssertTrue(preferences.undoManager.canUndo)
        preferences.undoManager.undo()
        XCTAssertEqual(preferences.layout, before)
        preferences.layout.hidden = [codex.id, claude.id]
        preferences.layout.onDemand = [codex.id, claude.id]
        preferences.resetCustomization(providerID: "codex")
        XCTAssertNil(preferences.layout.pins["codex"])
        XCTAssertEqual(preferences.layout.pins["claude"], [claude.id])
        XCTAssertEqual(preferences.layout.hidden, [claude.id])
        XCTAssertEqual(preferences.layout.onDemand, [claude.id])
        XCTAssertEqual(preferences.enabledProviders, ["codex", "claude"])
        XCTAssertEqual(preferences.entryPaths.path(for: "openrouter"), "existing/reference")
        XCTAssertFalse(preferences.undoManager.canUndo)
    }

    func testBalanceIsPinnableWithoutInventingUsageOrLimit() throws {
        let snapshot = AIUsageSnapshot(providerID: "openrouter", meters: [], balance: 12.5, currency: "USD", source: "fixture")
        let metric = try XCTUnwrap(AIUsageMetric.metrics(snapshot: snapshot).first)
        XCTAssertTrue(metric.isBalance)
        XCTAssertEqual(metric.value(remaining: true), "12.50 USD")
        XCTAssertEqual(metric.value(remaining: false), "12.50 USD")
        XCTAssertNil(metric.fraction(remaining: true))
        XCTAssertNil(metric.reset(absolute: false, now: Date()))
        var layout = AIUsageLayout()
        XCTAssertTrue(layout.togglePin(metric.id, provider: "openrouter"))
    }
}

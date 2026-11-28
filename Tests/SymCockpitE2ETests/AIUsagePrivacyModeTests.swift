import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

/// #451: with Privacy Mode on, a screen capture hides the usage values.
final class AIUsagePrivacyModeTests: XCTestCase {
    @MainActor
    private func model(captured: @escaping @MainActor () -> Bool) -> (AIUsageViewModel, AIUsagePreferences) {
        let name = NSTemporaryDirectory() + "AIUsagePrivacyModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["p"]
        preferences.menuBarEnabled = true
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { _, _ in [] })
        model.isScreenCaptured = captured
        let snapshot = AIUsageSnapshot(providerID: "p", meters: [.init(label: "Weekly", used: 25, unit: .percent)],
                                       fetchedAt: Date(timeIntervalSince1970: 1234), source: "test fixture")
        model.apply([.init(providerID: "p", snapshot: snapshot, error: nil)])
        preferences.layout.togglePin(model.metrics(for: model.rows[0])[0].id, provider: "p")
        return (model, preferences)
    }

    @MainActor
    func testACaptureHidesTheMenuBarValuesOnlyWithPrivacyModeOn() async {
        var captured = true
        let (model, preferences) = model(captured: { captured })
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.isConcealing, "Privacy Mode is off by default")
        XCTAssertEqual(model.statusPins.first?.value, "75%")

        preferences.concealWhileCaptured = true
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.isConcealing)
        XCTAssertTrue(model.statusPins.isEmpty)
        XCTAssertTrue(model.statusItemText.isEmpty)

        captured = false
        model.checkCapture()
        XCTAssertFalse(model.isConcealing, "the values return when the capture ends")
        XCTAssertEqual(model.statusPins.first?.value, "75%")
        model.stop()
    }

    @MainActor
    func testTheCopiedImageCarriesNoValuesWhileConcealed() throws {
        _ = NSApplication.shared
        let (model, preferences) = model(captured: { true })
        let row = try XCTUnwrap(model.rows.first)
        let card = { (concealed: Bool) in
            AIUsageShareCard(row: row, metrics: model.metrics(for: row), layout: preferences.layout,
                             now: Date(timeIntervalSince1970: 2000), concealed: concealed).png(appearance: .light)
        }
        let plain = try XCTUnwrap(card(false))
        XCTAssertEqual(card(false), plain, "rendering is deterministic")
        XCTAssertNotEqual(try XCTUnwrap(card(true)), plain)
    }

    @MainActor
    func testTheSettingIsInTheDisplayMenuAndPersists() async throws {
        _ = NSApplication.shared
        let name = NSTemporaryDirectory() + "AIUsagePrivacyModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AIUsagePreferences(defaults: defaults)
        let menu = NSHostingMenu(rootView: AIUsageDisplayControls(preferences: preferences))
        menu.update()
        let item = try XCTUnwrap(menu.items.firstIndex { $0.title == "Hide usage while the screen is shared or recorded" })
        menu.performActionForItem(at: item)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(AIUsagePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name))).concealWhileCaptured)
    }
}

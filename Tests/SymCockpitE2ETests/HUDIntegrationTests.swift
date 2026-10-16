import AppKit
import SwiftUI
import SymCockpitCore
import XCTest
@testable import SymCockpitUI

/// Production preference/host integration. No hardware controller is started.
final class HUDIntegrationTests: XCTestCase {
    @MainActor
    func testSavedHUDChoiceAndActionsUseTheProductionHost() async throws {
        _ = NSApplication.shared
        let suite = "com.symaira.cockpit.hud-integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let surface = ReadoutSurfacePreferences(defaults: defaults)
        XCTAssertEqual(surface.surface, .menuBar, "HUD must remain opt-in")
        surface.surface = .notch
        XCTAssertEqual(ReadoutSurfacePreferences(defaults: defaults).surface, .notch)
        XCTAssertTrue(defaults.bool(forKey: ReadoutSurfaceDefaults.legacyNotchEnabledKey))
        let dock = HUDDockPreferences(defaults: defaults)
        dock.dock = .right(.center)
        XCTAssertEqual(HUDDockPreferences(defaults: defaults).dock, .right(.center))
        let items = HUDItemPreferences(defaults: defaults)
        items.layout = HUDItemLayout()
        XCTAssertEqual(HUDItemPreferences(defaults: defaults).layout, HUDItemLayout())
        items.resetToDefault()
        XCTAssertEqual(HUDItemPreferences(defaults: defaults).layout, .default)
        guard HUDDockController.isAvailable(dock: dock.dock) else { throw XCTSkip("Needs a window server") }

        let controller = HUDDockController(dockPreferences: dock, itemPreferences: items,
                                           resolveItems: { _ in [] }, onDetailVisibility: { _ in })
        var actions: [String] = []
        controller.openPanel = { actions.append("panel") }
        controller.openCockpit = { actions.append("cockpit") }
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        let host = try XCTUnwrap(controller.panelAnchor()?.view as? NSHostingView<HUDDockView>)
        XCTAssertEqual(host.rootView.openCockpitTitle, "Cockpit", "Use the compact label, not the longer menu title")
        host.rootView.onToggle()
        XCTAssertEqual(host.rootView.presentation, .expanded)
        host.rootView.openPanel()
        XCTAssertEqual(actions, ["panel"])
        XCTAssertEqual(host.rootView.presentation, .collapsed)
        XCTAssertNotNil(controller.panelAnchor(), "The shared popover needs the HUD anchor after collapse")
        host.rootView.onToggle()
        host.rootView.openCockpit()
        XCTAssertEqual(actions, ["panel", "cockpit"])
        XCTAssertEqual(host.rootView.presentation, .collapsed)
        surface.surface = .menuBar
        controller.setEnabled(false)
        XCTAssertNil(controller.panelAnchor())
        XCTAssertEqual(ReadoutSurfacePreferences(defaults: defaults).surface, .menuBar)
        XCTAssertEqual(HUDDockPreferences(defaults: defaults).dock, .right(.center), "Disabling must keep its dock")
    }

    func testProductionWiringUsesSharedModelAndNeverDemoValues() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let status = try source("tuning/Sources/SymCockpitUI/StatusBarController.swift")
        XCTAssertTrue(status.contains("private lazy var hudController = HUDDockController(\n        model: model,"))
        XCTAssertTrue(status.contains("self?.togglePanelFromHUD()"))
        XCTAssertTrue(status.contains("self?.onOpenCockpit?()"))
        XCTAssertTrue(status.contains("hudController.setEnabled(effective == .notch)"))
        XCTAssertTrue(status.contains("statusItem.isVisible = effective == .menuBar"))
        XCTAssertFalse(status.contains("hudController.openCockpitTitle = openCockpitTitle"))
        let hud = try source("tuning/Sources/SymCockpitUI/HUDDockController.swift")
        XCTAssertTrue(hud.contains("HUDItemResolver.values(for: $0, model: model)"))
        XCTAssertTrue(hud.contains("model.setDetailVisible($0)"))
        for file in [status, hud, try source("tuning/Sources/SymCockpitUI/HUDItemRendering.swift")] {
            XCTAssertFalse(file.contains("HUDDemoController"))
            XCTAssertFalse(file.contains("exampleValues"))
        }
    }
}

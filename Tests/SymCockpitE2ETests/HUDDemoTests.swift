import AppKit
import SwiftUI
import SymCockpitCore
import XCTest
@testable import SymCockpitUI

final class HUDDemoTests: XCTestCase {
    @MainActor
    func testDemoUsesProductionPresentationWithoutHardwareOrPersistence() async throws {
        _ = NSApplication.shared
        guard let screen = HUDDockController.hostScreen() else { throw XCTSkip("Needs a window server") }
        let dock = HUDDockPreferences(defaults: nil)
        let items = HUDItemPreferences(defaults: nil)
        dock.dock = .right(.center)
        XCTAssertEqual(HUDDockPreferences(defaults: nil).dock, .notch)
        items.layout = HUDItemLayout()
        XCTAssertEqual(HUDItemPreferences(defaults: nil).layout, .default)
        items.resetToDefault()
        let values = HUDDemoController.exampleValues(items.layout.items(at: .expanded))
        XCTAssertEqual(values.count, items.layout.items(at: .expanded).count)
        XCTAssertEqual(values.first(where: { $0.kind == .metric(.cpu) })?.value, "24 %")
        var detail: [Bool] = []
        let controller = HUDDockController(
            dockPreferences: dock, itemPreferences: items,
            resolveItems: HUDDemoController.exampleValues, onDetailVisibility: { detail.append($0) }
        )
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        let anchor = try XCTUnwrap(controller.panelAnchor())
        let host = try XCTUnwrap(anchor.view as? NSHostingView<HUDDockView>)
        XCTAssertEqual(host.window?.frame, screen.frame)
        host.rootView.onToggle()
        XCTAssertEqual(host.rootView.presentation, .expanded)
        host.rootView.onToggle()
        XCTAssertEqual(host.rootView.presentation, .peek)
        XCTAssertEqual(detail, [true, false])
        let metrics = HUDDockController.screenMetrics(screen)
        let target = try XCTUnwrap(HUDDockLayout.collapsedFrame(.left(.center), on: metrics))
        host.rootView.onDragEnded(CGPoint(x: target.midX, y: target.midY))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(dock.dock, .left(.center))
        XCTAssertEqual(host.rootView.dock, .left(.center))
        XCTAssertTrue(controller.panelAnchor()?.view === host)
        controller.setEnabled(false)
        XCTAssertNil(controller.panelAnchor())
        XCTAssertFalse(controller.isEnabled)
    }

    func testDemoSourceIsDebugOnlyAndNeverStartsTheHardwareModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "tuning/Sources/SymCockpitUI/HUDDemoController.swift"), encoding: .utf8)
        XCTAssertTrue(source.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(source.hasSuffix("#endif\n"))
        XCTAssertTrue(source.contains("Beispieldaten · Keine Hardwarezugriffe"))
        for forbidden in ["TuneController(", "TuneViewModel(", "StatusBarController(", "UserDefaults.standard", "Process(", "URLSession"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

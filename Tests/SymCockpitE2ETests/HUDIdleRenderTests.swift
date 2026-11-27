import SymCockpitCore
import XCTest
@testable import SymCockpitUI

/// The parked HUD shoulders are always-present SwiftUI surfaces: a metrics
/// tick that leaves the displayed value alone must not invalidate them, and a
/// changed value must swap its digits without an interpolated (software-blurred)
/// glyph layer. Issue #418.
final class HUDIdleRenderTests: XCTestCase {
    private func readout(_ value: String) -> HUDItemValue {
        HUDItemValue(
            kind: .metric(.cpu),
            title: "CPU",
            value: value,
            symbolName: "cpu",
            isActive: false
        )
    }

    @MainActor
    func testCompactReadoutSkipsWorkForUnchangedValue() {
        let view = HUDCompactItem(item: readout("12 %"), fitsWidth: true)
        XCTAssertEqual(view, HUDCompactItem(item: readout("12 %"), fitsWidth: true))
        XCTAssertNotEqual(view, HUDCompactItem(item: readout("13 %"), fitsWidth: true))
        XCTAssertNotEqual(view, HUDCompactItem(item: readout("12 %"), fitsWidth: false))
    }

    @MainActor
    func testStackedReadoutSkipsWorkForUnchangedValue() {
        let view = HUDStackedItem(item: readout("12 %"))
        XCTAssertEqual(view, HUDStackedItem(item: readout("12 %")))
        XCTAssertNotEqual(view, HUDStackedItem(item: readout("13 %")))
    }

    func testNumericTransitionIsReservedForTheExpandedCard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("tuning/Sources/SymCockpitUI/HUDItemViews.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("struct HUDCompactItem: View, Equatable"))
        XCTAssertTrue(source.contains("struct HUDStackedItem: View, Equatable"))
        XCTAssertEqual(
            source.components(separatedBy: ".contentTransition(.numericText())").count - 1,
            1,
            "Only the expanded card may animate digits; the always-on HUD surfaces draw them outright"
        )
    }

    func testHiddenSurfacesReleaseTheirSwiftUIGraph() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let statusBar = try source("tuning/Sources/SymCockpitUI/StatusBarController.swift")
        XCTAssertTrue(statusBar.contains("popover.contentViewController = nil"))
        let window = try source("Sources/SymCockpitApp/CockpitWindowController.swift")
        XCTAssertTrue(window.contains("window?.contentViewController = nil"))
    }
}

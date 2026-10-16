import AppKit
import Observation
import SwiftUI
import SymCockpitCore
import SymairaTheme
import XCTest
@testable import SymCockpitUI

/// Native production-view renders with labelled fixtures, never a TuneController.
/// This does not exercise real screen docking, hardware or VoiceOver.
final class HUDDesignTests: XCTestCase {
    @MainActor
    func testMountedHUDTracksAppearanceAndResolvedValues() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        let preferences = CockpitAppearancePreferences(defaults: nil)
        preferences.selection = .light
        let state = HUDReadingFixture()
        let metrics = NotchScreenMetrics(frame: CGRect(x: 0, y: 0, width: 960, height: 720),
                                         menuBarHeight: 37, leftAuxiliaryWidth: 380, rightAuxiliaryWidth: 380)
        let root = HUDDockView(
            resolveItems: { kinds in kinds.map { kind in
                HUDItemValue(kind: kind, title: kind.displayName, value: state.value,
                             symbolName: kind.symbolName, isActive: false)
            } }, itemLayout: .default, metrics: metrics, dock: .right(.center), presentation: .expanded,
            notchWidth: 200, menuBarHeight: 37, openPanel: {}, openCockpit: {}, openCockpitTitle: "Cockpit",
            onToggle: {}, onDragChanged: { _ in }, onDragEnded: { _ in }
        )
        let host = NSHostingView(rootView: root.transaction { $0.animation = nil })
        let panel = HUDStagePanel(contentRect: metrics.frame)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        host.frame = metrics.frame
        defer { panel.close() }
        func snapshot() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(100))
        let initial = try snapshot()
        state.value = "88 %"
        try await Task.sleep(for: .milliseconds(350))
        let updated = try snapshot()
        XCTAssertNotEqual(initial, updated, "Model reads inside the resolver must remain observed")
        preferences.selection = .dark
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(updated, try snapshot(), "An already mounted HUD must change appearance")
        XCTAssertTrue(panel.contentView === host, "Neither theme nor values should remount the HUD")
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    @MainActor
    func testAllDockShapesAndStagesFollowAppearanceWithoutChangingCameraClearance() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        let preferences = CockpitAppearancePreferences(defaults: nil)
        for scheme in [ColorScheme.light, .dark] {
            preferences.selection = scheme == .light ? .light : .dark
            for dock in [HUDDock.notch, .left(.center), .right(.center)] {
                for stage in HUDPresentation.allCases {
                    try await render(dock: dock, stage: stage, scheme: scheme, layout: .default, suffix: "default")
                }
                try await render(dock: dock, stage: .expanded, scheme: scheme, layout: HUDItemLayout(), suffix: "empty")
                let all = HUDItemLayout(placements: Dictionary(uniqueKeysWithValues: HUDItemKind.allCases.map {
                    ($0, HUDItemPlacement(isEnabled: true, side: .left, stage: .expanded))
                }))
                try await render(dock: dock, stage: .expanded, scheme: scheme, layout: all, suffix: "all-short", height: 260)
            }
        }
    }

    @MainActor
    private func render(
        dock: HUDDock, stage: HUDPresentation, scheme: ColorScheme,
        layout: HUDItemLayout, suffix: String, height: CGFloat = 720
    ) async throws {
        let name = "\(dock.storageKey)-\(stage.rawValue)-\(scheme)-\(suffix)"
        let metrics = NotchScreenMetrics(frame: CGRect(x: 0, y: 0, width: 960, height: height),
                                         menuBarHeight: 37, leftAuxiliaryWidth: 380, rightAuxiliaryWidth: 380)
        let contentHeight = HUDDockLayout.expandedContentHeight(for: layout, dock: dock)
        let global = try XCTUnwrap(HUDDockLayout.frame(dock, on: metrics, presentation: stage, contentHeight: contentHeight))
        let target = CGRect(x: global.minX, y: metrics.frame.maxY - global.maxY, width: global.width, height: global.height)
        let root = HUDDockView(
            resolveItems: { kinds in kinds.map(Self.fixture) }, itemLayout: layout,
            metrics: metrics, dock: dock, presentation: stage,
            notchWidth: 200, menuBarHeight: metrics.menuBarHeight,
            openPanel: {}, openCockpit: {}, openCockpitTitle: "Cockpit",
            onToggle: {}, onDragChanged: { _ in }, onDragEnded: { _ in }
        )
        // Exercise inherited NSApplication appearance, not an explicit colorScheme override.
        let host = NSHostingView(rootView: root
            .background(alignment: .bottomLeading) {
                SymairaTheme.surfaceOpaque(for: scheme).frame(width: 10, height: 10)
            }
            .transaction { $0.animation = nil })
        let panel = HUDStagePanel(contentRect: metrics.frame)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        host.frame = metrics.frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                       scheme == .dark ? .darkAqua : .aqua, name)
        XCTAssertEqual(host.bounds.size, metrics.frame.size, name)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / metrics.frame.width
        func color(_ point: CGPoint) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        }
        if stage == .expanded {
            // Bottom padding is content surface, independent of values/controls.
            let actual = try color(CGPoint(x: target.midX, y: target.maxY - 5))
            // Compare a token swatch from the same display-profile bitmap, not
            // unrendered sRGB components against a monitor-profile conversion.
            let expected = try color(CGPoint(x: 4, y: height - 4))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01, name)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01, name)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01, name)
            if scheme == .light {
                XCTAssertGreaterThan(actual.redComponent, 0.7, name)
            } else {
                XCTAssertLessThan(actual.redComponent, 0.2, name)
            }
        }
        if dock == .notch {
            let camera = try color(CGPoint(x: metrics.frame.midX, y: 12))
            XCTAssertLessThan(camera.redComponent, 0.01, name)
            XCTAssertLessThan(camera.greenComponent, 0.01, name)
            XCTAssertLessThan(camera.blueComponent, 0.01, name)
        } else if stage != .expanded {
            let bezel = try color(CGPoint(x: target.midX, y: target.minY + 8))
            XCTAssertLessThan(bezel.redComponent, 0.01, name)
        }
        if let directory = ProcessInfo.processInfo.environment["COCKPIT_HUD_RENDER_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let crop = target.insetBy(dx: -12, dy: -12).intersection(metrics.frame)
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: pixels))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private static func fixture(_ kind: HUDItemKind) -> HUDItemValue {
        let values: [HUDItemKind: String] = [
            .metric(.cpu): "24 %", .metric(.memory): "62 %", .metric(.disk): "48 %",
            .metric(.network): "2 MB/s", .battery: "76 %", .calendarWeek: "W 42",
            .keepAwake: "Sleep allowed", .fanProfile: "Balanced (idle)"
        ]
        return HUDItemValue(kind: kind, title: kind.displayName, value: values[kind] ?? "12 %",
                            symbolName: kind.symbolName, isActive: kind == .battery)
    }
}

@MainActor @Observable
private final class HUDReadingFixture {
    var value = "12 %"
}

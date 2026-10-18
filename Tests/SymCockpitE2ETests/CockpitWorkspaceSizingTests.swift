import AppKit
import SwiftUI
import SymairaTheme
import XCTest
@testable import SymCockpitUI

final class CockpitWorkspaceSizingTests: XCTestCase {
    @MainActor
    func testNativeSidebarDragPreservesContentAndRespectsWindowBudget() async throws {
        _ = NSApplication.shared
        let root = CockpitWorkspaceView(
            version: "test", openPreferences: {}, appearance: CockpitAppearancePreferences(defaults: nil),
            content: {
                TuneSliderRow(title: "Test", systemImage: "sun.max", value: 0.43, range: 0...1, onCommit: { _ in })
            })
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let handle = try XCTUnwrap(descendants(window.contentView).first {
            $0.accessibilityIdentifier() == "symaira-sidebar-resize"
        })
        // Assert actual mounted geometry, not AppKit's private state/type.
        var sidebarWidth: CGFloat {
            handle.convert(NSPoint(x: handle.bounds.maxX, y: 0), to: window.contentView).x
        }
        let slider = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(sidebarWidth, 272)
        XCTAssertEqual(handle.accessibilityRole(), .splitter)

        for (distance, expected): (CGFloat, CGFloat) in [(56, 328), (200, 360), (-280, 64), (184, 248)] {
            let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            XCTAssertTrue(window.contentView?.hitTest(start) === handle, "The boundary must actually receive mouse input")
            for (type, x) in [(NSEvent.EventType.leftMouseDown, start.x),
                              (.leftMouseDragged, start.x + distance), (.leftMouseUp, start.x + distance)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(40))
            }
            XCTAssertEqual(sidebarWidth, expected, accuracy: 0.5)
            let current = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(current === slider, "Dragging must not recreate controls")
            XCTAssertEqual(current.doubleValue, 0.43, accuracy: 0.001)
        }
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sidebarWidth, 264)
        XCTAssertTrue(handle.accessibilityPerformDecrement())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sidebarWidth, 248)

        window.setContentSize(NSSize(width: 800, height: 760))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sidebarWidth, 232, "Preserve at least 568 points for content")
        window.setContentSize(NSSize(width: 620, height: 760))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sidebarWidth, 64)
        XCTAssertFalse(handle.isAccessibilityEnabled())
        window.setContentSize(NSSize(width: 1080, height: 760))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sidebarWidth, 248, "Restore the chosen width after temporarily compacting")

        var layout = SymairaSidebarState()
        layout.resize(to: 328)
        layout.expanded.toggle()
        XCTAssertEqual(layout.width, 64)
        layout.expanded.toggle()
        XCTAssertEqual(layout.width, 328, "Toolbar toggling must remember the resized width")
    }

    @MainActor
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    func testKeepAwakeActionKeepsItsSizeAndChangesColor() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [280, 720] {
                var images: [CGImage] = []
                for active in [false, true] {
                    let card = KeepAwakeCard(
                        active: active, preventDisplaySleep: .constant(false), durationIndex: .constant(0),
                        remaining: nil, isInteractive: true, presets: [("Indefinite", nil)], onToggle: {})
                    let renderer = ImageRenderer(content: card.sessionButton
                        .frame(width: width).environment(\.colorScheme, scheme))
                    renderer.scale = 2
                    images.append(try XCTUnwrap(renderer.cgImage))
                }
                XCTAssertEqual(images[0].width, images[1].width, "Start/End width must match")
                XCTAssertEqual(images[0].height, images[1].height, "Start/End height must match")
                XCTAssertEqual(images[0].height, 80, "40-point action target in both states")
                // Away from the text and rounded corners: the surface still changes color.
                let pixels = try images.map { image -> [UInt8] in
                    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                    let context = try XCTUnwrap(CGContext(
                        data: &bytes, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    let offset = ((image.height / 2) * image.width + 40) * 4
                    return Array(bytes[offset..<(offset + 3)])
                }
                XCTAssertNotEqual(pixels[0], pixels[1], "Session state must still change the button color")
            }
        }
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import SymCockpitUI

final class CockpitBarColorTests: XCTestCase {
    @MainActor
    func testNativeSliderAndProgressUseIdenticalFillAndRailInBothModes() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
            var sliderImage: NSBitmapImageRep?
            var meterImage: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                let control = EffortSliderControl(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
                let cell = EffortSliderCell()
                control.cell = cell
                cell.controlView = control
                cell.minValue = 0
                cell.maxValue = 1
                cell.doubleValue = 0.5
                cell.guideCount = 2
                let native = NSImage(size: NSSize(width: 320, height: 34), flipped: false) { _ in
                    cell.drawBar(inside: NSRect(x: 0, y: 0, width: 320, height: 34), flipped: false)
                    return true
                }
                if let image = native.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    sliderImage = NSBitmapImageRep(cgImage: image)
                }
                let renderer = ImageRenderer(content:
                    ProgressView(value: 0.5)
                        .progressViewStyle(CockpitProgressStyle())
                        .frame(width: 320)
                        .environment(\.colorScheme, scheme))
                renderer.scale = 1
                if let image = renderer.cgImage { meterImage = NSBitmapImageRep(cgImage: image) }
            }
            let slider = try XCTUnwrap(sliderImage)
            let meter = try XCTUnwrap(meterImage)
            for x in [50, 250] {
                // NSImage uses the display's backing scale; ImageRenderer is fixed at 1x.
                let native = try XCTUnwrap(slider.colorAt(
                    x: x * slider.pixelsWide / 320, y: 17 * slider.pixelsHigh / 34
                )?.usingColorSpace(.sRGB))
                let swiftUI = try XCTUnwrap(meter.colorAt(x: x, y: 4)?.usingColorSpace(.sRGB))
                XCTAssertEqual(native.redComponent, swiftUI.redComponent, accuracy: 1.0 / 255, "\(scheme) x=\(x)")
                XCTAssertEqual(native.greenComponent, swiftUI.greenComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(native.blueComponent, swiftUI.blueComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(native.alphaComponent, 1)
                XCTAssertEqual(swiftUI.alphaComponent, 1)
            }
        }
    }
}

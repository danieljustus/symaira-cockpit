import AppKit
import SwiftUI
import SymTuneCore
import XCTest
@testable import SymTuneUI

final class EffortSliderTests: XCTestCase {
    @MainActor
    func testNativeKnobMatchesEndpointsAndCentreWithoutOverflow() async {
        let control = EffortSliderControl(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        let cell = EffortSliderCell()
        control.cell = cell
        cell.controlView = control
        cell.minValue = -1
        cell.maxValue = 1
        let bar = cell.barRect(flipped: true)
        XCTAssertEqual(bar.width, 320)
        for (value, expectedX) in [(-1.0, bar.minX), (0.0, bar.midX - 10), (1.0, bar.maxX - 20)] {
            cell.doubleValue = value
            let knob = cell.knobRect(flipped: true)
            XCTAssertEqual(knob.width, 20)
            XCTAssertEqual(knob.height, 20)
            XCTAssertEqual(knob.minX, expectedX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(knob.minX, bar.minX)
            XCTAssertLessThanOrEqual(knob.maxX, bar.maxX)
        }
    }

    @MainActor
    func testFanDetentsMapOnlyToExistingProfiles() async {
        let cell = EffortSliderCell()
        cell.minValue = 0
        cell.maxValue = Double(FanProfile.ordered.count - 1)
        cell.numberOfTickMarks = FanProfile.ordered.count
        cell.allowsTickMarkValuesOnly = true
        for profile in FanProfile.ordered {
            XCTAssertEqual(cell.tickMarkValue(at: profile.step), Double(profile.step))
            XCTAssertEqual(FanProfile.at(step: profile.step), profile)
        }
        XCTAssertEqual(cell.closestTickMarkValue(toValue: 0.4), 0)
        XCTAssertEqual(cell.closestTickMarkValue(toValue: 0.6), 1)
        XCTAssertEqual(cell.closestTickMarkValue(toValue: 1.8), 2)
    }

    @MainActor
    func testNativeActionPublishesValueAndReflectsBindingSnap() async {
        var value = 0.0
        var changes = 0
        let slider = EffortSlider(
            value: Binding(get: { value }, set: { value = $0 < 0.04 ? 0 : $0; changes += 1 }),
            range: 0...1, label: "Screen Brightness", valueDescription: "0%", onEditingChanged: { _ in }
        )
        let coordinator = EffortSlider.Coordinator(parent: slider)
        let control = EffortSliderControl()
        control.cell = EffortSliderCell()
        control.minValue = 0
        control.maxValue = 1
        control.doubleValue = 0.62
        coordinator.valueChanged(control)
        XCTAssertEqual(value, 0.62)
        XCTAssertEqual(changes, 1)
        control.doubleValue = 0.02
        coordinator.valueChanged(control)
        XCTAssertEqual(value, 0)
        XCTAssertEqual(control.doubleValue, 0)
        XCTAssertEqual(changes, 2)
    }
}

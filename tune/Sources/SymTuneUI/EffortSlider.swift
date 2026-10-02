import AppKit
import SwiftUI
import SymairaTheme

/// Codex-style chrome on a real native slider, not a drag-only imitation.
/// AppKit retains keyboard, accessibility, tick snapping and pointer tracking.
@MainActor
struct EffortSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tickCount = 6
    var snapsToTicks = false
    var isEnabled = true
    let label: String
    let valueDescription: String
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> EffortSliderControl {
        let control = EffortSliderControl()
        control.cell = EffortSliderCell()
        control.isContinuous = true
        control.target = context.coordinator
        control.action = #selector(Coordinator.valueChanged(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: EffortSliderControl, context: Context) {
        context.coordinator.parent = self
        control.minValue = range.lowerBound
        control.maxValue = range.upperBound
        // Guide dots must not coarsen continuous brightness or keyboard steps.
        control.numberOfTickMarks = snapsToTicks ? tickCount : 0
        control.allowsTickMarkValuesOnly = snapsToTicks
        (control.cell as? EffortSliderCell)?.guideCount = tickCount
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(label)
        control.setAccessibilityValueDescription(valueDescription)
        control.editingChanged = { context.coordinator.parent.onEditingChanged($0) }
        if !control.isDragging {
            control.doubleValue = value
        }
        control.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: EffortSlider

        init(parent: EffortSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.doubleValue
            // Reflect row-level centre snapping without touching its model.
            sender.doubleValue = parent.value
        }
    }
}

@MainActor
final class EffortSliderControl: NSSlider {
    var editingChanged: (Bool) -> Void = { _ in }
    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        editingChanged(true)
        super.mouseDown(with: event)
        isDragging = false
        editingChanged(false)
    }
}

@MainActor
final class EffortSliderCell: NSSliderCell {
    var guideCount = 6
    static let knobDiameter: CGFloat = 20

    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        let travel = max(0, bar.width - Self.knobDiameter)
        return NSRect(
            x: bar.minX + travel * CGFloat(min(1, max(0, fraction))),
            y: bar.midY - Self.knobDiameter / 2,
            width: Self.knobDiameter, height: Self.knobDiameter
        )
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let inset = Self.knobDiameter / 2
        // Put endpoint dots inside the rounded caps, not on their outer edge.
        let rail = NSRect(x: rect.minX + inset - 4, y: rect.midY - 4, width: max(0, rect.width - 2 * inset + 8), height: 8)
        let path = NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4)
        NSColor(SymairaTheme.textMuted).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        path.fill()

        let thumb = knobRect(flipped: flipped)
        let filled = NSRect(x: rail.minX, y: rail.minY, width: max(0, thumb.midX - rail.minX), height: rail.height)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(SymairaTheme.goldPrimary).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        filled.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(SymairaTheme.bgDark).setFill()
        for index in 0..<max(2, guideCount) {
            let x = rect.minX + inset + max(0, rect.width - 2 * inset) * CGFloat(index) / CGFloat(max(2, guideCount) - 1)
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: rail.midY - 2, width: 4, height: 4)).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let circle = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
        NSColor(isEnabled ? SymairaTheme.textPrimary : SymairaTheme.textSecondary).setFill()
        circle.fill()
        NSColor(SymairaTheme.bgDark).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    // Native detents stay active; their markings are the dots inside our rail.
    override func drawTickMarks() { }
}

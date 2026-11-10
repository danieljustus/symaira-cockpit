import SwiftUI
import SymairaTheme

/// Maps the SF Symbol vocabulary that `SymCockpitCore` still exposes (the menu
/// bar status item and notch need real `NSImage` symbols) onto `SymairaIcon`
/// cases for every SwiftUI surface, so no view in this module names an SF Symbol
/// (GUIDELINES ICON-1).
///
/// A few symbols have no matching `SymairaIcon` case yet (battery levels, a
/// memory chip, a coffee cup). They map to the nearest neutral case and are
/// tracked as AppKit icon gaps; the value next to each icon always carries the
/// actual information.
enum CockpitIcon {
    static func icon(forSymbol name: String) -> SymairaIcon {
        switch name {
        case "cpu", "cpu.fill": .cpu
        case "memorychip", "memorychip.fill": .server
        case "internaldrive": .storage
        case "externaldrive": .device
        case "arrow.up.arrow.down": .network
        case "calendar": .calendar
        case "fan", "fanblades", "fanblades.fill": .fan
        case "thermometer.medium", "thermometer.sun.fill", "gauge.with.needle.fill": .temperature
        case "sun.max", "sun.max.fill": .lightMode
        case "circle.lefthalf.filled": .appearance
        case "gauge.with.dots.needle.50percent", "gauge.with.dots.needle.bottom.50percent": .productCockpit
        case "slider.horizontal.3": .tune
        case "macwindow", "menubar.rectangle": .window
        case "display", "rectangle.topthird.inset.filled": .device
        case "house": .home
        case "bolt": .energy
        case "chart.xyaxis.line": .chart
        case "arrow.up.right": .openExternal
        case "rectangle.3.group": .dashboard
        case "sparkles": .ai
        case "eye": .visible
        case "info.circle", "info.circle.fill": .info
        case "checkmark.circle.fill": .success
        case "xmark.circle.fill": .failure
        case "exclamationmark.circle", "exclamationmark.triangle": .warning
        case "exclamationmark.octagon": .error
        case "clock.badge.xmark", "cup.and.saucer", "cup.and.saucer.fill": .time
        case "arrow.up.circle.fill": .download
        case "arrow.clockwise": .refresh
        case "arrow.up", "chevron.up": .collapse
        case "arrow.down", "chevron.down": .expand
        case "chevron.right": .forward
        case "star.fill": .favorite
        case "ellipsis": .more
        case _ where name.hasPrefix("battery"): .power
        default: .dashboard
        }
    }
}

extension SymairaIconView where Trigger == Int {
    /// An icon for a Core-provided SF Symbol name at an explicit point size.
    init(symbol name: String, size: CGFloat) {
        self.init(CockpitIcon.icon(forSymbol: name), size: size)
    }
}

extension Label where Title == Text, Icon == SymairaIconView<Int> {
    /// A text-sized `Label` with a Symaira icon. `Label(_:symairaIcon:)` draws
    /// its icon at 20 pt, which is too large for the dense cards.
    @MainActor
    init(_ title: String, symairaIcon icon: SymairaIcon, iconSize: CGFloat) {
        self.init {
            Text(title)
        } icon: {
            SymairaIconView(icon, size: iconSize)
        }
    }
}

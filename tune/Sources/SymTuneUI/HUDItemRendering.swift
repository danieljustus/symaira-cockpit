import Foundation
import SymTuneCore

/// One HUD item, resolved to the strings the view draws.
///
/// The view never reaches into the model for an item's value, so the mapping
/// from "the user asked for the battery" to "82 %" exists once. That matters
/// more than it looks: the same item is drawn three ways — compact on a
/// shoulder, as a row in the card, and as a settings preview — and three call
/// sites formatting the same number independently is how they drift apart.
struct HUDItemValue: Identifiable, Equatable {
    let kind: HUDItemKind
    /// Long form, for the card: `Memory`.
    let title: String
    /// What the number or state actually is: `62 %`, `Awake`, `KW 37`.
    let value: String
    /// SF Symbol drawn beside it.
    let symbolName: String
    /// Whether this item is currently *doing* something, as opposed to merely
    /// reporting. Drives the accent: an idle fan profile is not worth gold.
    let isActive: Bool

    var id: String { kind.rawValue }
}

/// Turning the view model into HUD items.
///
/// An item with nothing behind it is **dropped**, not drawn as a placeholder.
/// A HUD reading `RAM --` is worse than a HUD one readout shorter, and on a
/// shoulder 64 points wide it is also indistinguishable from a bug.
@MainActor
enum HUDItemResolver {
    /// Resolve `kinds` against the model, skipping the ones with no data.
    static func values(
        for kinds: [HUDItemKind],
        model: TuneViewModel,
        now: Date = Date()
    ) -> [HUDItemValue] {
        kinds.compactMap { value(for: $0, model: model, now: now) }
    }

    static func value(
        for kind: HUDItemKind,
        model: TuneViewModel,
        now: Date = Date()
    ) -> HUDItemValue? {
        if let metric = kind.metric {
            // Absent from `metricRows` means the metric is not being monitored,
            // which is a decision the user already made in the menu-bar
            // switches. The HUD honours it rather than sampling behind its back.
            guard let row = model.metricRows.first(where: { $0.id == metric }) else { return nil }
            return HUDItemValue(
                kind: kind,
                title: row.title,
                value: row.current,
                symbolName: metric.statusItemSymbol,
                isActive: false
            )
        }

        switch kind {
        case .battery:
            guard let battery = model.battery,
                  battery.present,
                  let percent = battery.currentCapacityPercent
            else { return nil }
            return HUDItemValue(
                kind: kind,
                title: "Battery",
                value: "\(percent) %",
                symbolName: batterySymbol(percent: percent, charging: battery.charging == true),
                isActive: battery.charging == true
            )

        case .calendarWeek:
            return HUDItemValue(
                kind: kind,
                title: "Calendar week",
                value: CalendarWeekFormatting.text(for: now),
                symbolName: kind.symbolName,
                isActive: false
            )

        case .keepAwake:
            let active = model.keepAwake.active
            return HUDItemValue(
                kind: kind,
                title: "Keep awake",
                value: active ? "Awake" : "Sleep allowed",
                symbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                isActive: active
            )

        case .fanProfile:
            let selected = model.fanProfile != .system
            // A profile with no privileged governor behind it is a selection,
            // not a state the fans are in, and the readout says so rather than
            // claiming a curve that is not being enforced.
            let suffix = selected && !model.fanGovernorRunning ? " (idle)" : ""
            return HUDItemValue(
                kind: kind,
                title: "Fan profile",
                value: model.fanProfile.displayName + suffix,
                symbolName: kind.symbolName,
                isActive: selected && model.fanGovernorRunning
            )

        default:
            return nil
        }
    }

    /// The battery glyph for a level, so the icon carries the reading too — on
    /// a shoulder that is a good deal of information for no extra width.
    private static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

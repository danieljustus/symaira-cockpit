import Foundation

/// One thing the HUD can show.
///
/// A `RawRepresentable` struct rather than an enum, for the same reason
/// ``MetricIdentifier`` is one: the set is written into a user's defaults, and
/// a build that meets a kind it does not know must be able to keep the string
/// and ignore it rather than fail to decode the whole layout.
///
/// Metrics are namespaced (`metric.cpu`) so a metric added later needs no new
/// case here — it becomes a HUD item the moment it becomes a metric.
public struct HUDItemKind: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The HUD item that shows `metric`.
    public static func metric(_ metric: MetricIdentifier) -> HUDItemKind {
        HUDItemKind(rawValue: "metric.\(metric.rawValue)")
    }

    /// The metric behind this item, or `nil` for the non-metric items.
    public var metric: MetricIdentifier? {
        guard rawValue.hasPrefix("metric.") else { return nil }
        return MetricIdentifier(rawValue: String(rawValue.dropFirst("metric.".count)))
    }

    public static let battery = HUDItemKind(rawValue: "battery")
    public static let calendarWeek = HUDItemKind(rawValue: "calendarWeek")
    public static let keepAwake = HUDItemKind(rawValue: "keepAwake")
    public static let fanProfile = HUDItemKind(rawValue: "fanProfile")

    /// Everything the HUD knows how to draw, in the order the settings list
    /// them: the metrics first, because they are what people came for, then
    /// the machine's own state.
    public static var allCases: [HUDItemKind] {
        MetricIdentifier.allCases.map(HUDItemKind.metric)
            + [.battery, .calendarWeek, .keepAwake, .fanProfile]
    }

    public var displayName: String {
        if let metric { return metric.displayName }
        switch self {
        case .battery: return "Battery"
        case .calendarWeek: return "Calendar week"
        case .keepAwake: return "Keep awake"
        case .fanProfile: return "Fan profile"
        default: return rawValue
        }
    }

    /// The SF Symbol drawn beside the value.
    public var symbolName: String {
        if let metric { return metric.statusItemSymbol }
        switch self {
        case .battery: return "battery.100"
        case .calendarWeek: return "calendar"
        case .keepAwake: return "cup.and.saucer"
        case .fanProfile: return "fan"
        default: return "circle"
        }
    }

    /// Whether the item needs the metric sampler running behind it. A metric
    /// that is not being monitored has nothing to draw, and the settings say so
    /// rather than offering a switch that does nothing.
    public var requiresMonitoring: Bool { metric != nil }
}

/// Which shoulder of the HUD an item sits on.
///
/// The notch dock has two, either side of the cutout, and they are genuinely
/// different places: the left one overlaps the frontmost app's menu titles, the
/// right one overlaps everyone's status items. On an edge dock the sides become
/// the two columns of the card. Either way it is the user's call, because only
/// they know what is already up there.
public enum HUDItemSide: String, CaseIterable, Sendable {
    case left
    case right

    public var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// The three decisions the user makes about one item: whether it appears at
/// all, which side it appears on, and how far the HUD has to be open before it
/// does.
public struct HUDItemPlacement: Equatable, Sendable {
    public var isEnabled: Bool
    public var side: HUDItemSide
    /// The *earliest* presentation the item appears in; it stays visible in
    /// every wider one. See ``HUDPresentation``.
    public var stage: HUDPresentation

    public init(isEnabled: Bool, side: HUDItemSide, stage: HUDPresentation) {
        self.isEnabled = isEnabled
        self.side = side
        self.stage = stage
    }

    /// An item that is configured but currently switched off.
    public static let off = HUDItemPlacement(isEnabled: false, side: .left, stage: .expanded)
}

/// What the HUD shows, where, and when.
///
/// The HUD used to borrow the menu bar's `visible` set and take the first two
/// entries — which meant the notch could never show anything the status item
/// did not, and that the choice of *which* two was the list order rather than a
/// decision. This replaces that with a placement per item.
///
/// It stays a value type with string round-tripping and no `UserDefaults` in
/// sight, so the defaults, the migration and the visibility rule can all be
/// checked without a screen or a preferences file.
public struct HUDItemLayout: Equatable, Sendable {
    /// Placements by item. An item missing from here is **off**, not
    /// defaulted — see ``placement(for:)``.
    ///
    /// That is what makes "the user switched everything off" a layout this type
    /// can represent at all. Falling back to ``default`` here instead would
    /// make an empty layout indistinguishable from an unconfigured one, and the
    /// HUD would repopulate itself behind the user's back. The unconfigured
    /// case is handled one level up, where it belongs: nothing in storage means
    /// ``default``, and everything after that is a decision.
    ///
    /// It also decides the upgrade: an item introduced by a later release is
    /// absent from an existing stored layout, so it starts off. The HUD draws
    /// over the menu bar, and nothing new turns up there without being asked
    /// for.
    public var placements: [HUDItemKind: HUDItemPlacement]

    public init(placements: [HUDItemKind: HUDItemPlacement] = [:]) {
        self.placements = placements
    }

    // MARK: - Defaults

    /// What a HUD nobody has configured shows.
    ///
    /// Chosen to land on the behaviour the HUD already had — CPU and memory on
    /// the shoulders, everything else only once it is open — so that turning
    /// this feature on changes nothing until the user asks it to. The two
    /// remaining metrics move to the hover stage rather than straight to the
    /// card, because a peek that adds nothing is a peek nobody will use twice.
    public static let `default` = HUDItemLayout(placements: [
        .metric(.cpu): HUDItemPlacement(isEnabled: true, side: .left, stage: .collapsed),
        .metric(.memory): HUDItemPlacement(isEnabled: true, side: .right, stage: .collapsed),
        .metric(.disk): HUDItemPlacement(isEnabled: true, side: .left, stage: .peek),
        .metric(.network): HUDItemPlacement(isEnabled: true, side: .right, stage: .peek),
        // Not on the peeking shoulder: memory and network are already there, and
        // a shoulder fits two readouts. A third is drawn and then clipped,
        // which looks like a bug rather than like a budget.
        .battery: HUDItemPlacement(isEnabled: true, side: .right, stage: .expanded),
        .calendarWeek: HUDItemPlacement(isEnabled: false, side: .left, stage: .expanded),
        .keepAwake: HUDItemPlacement(isEnabled: true, side: .left, stage: .expanded),
        .fanProfile: HUDItemPlacement(isEnabled: true, side: .right, stage: .expanded),
    ])

    /// The placement for `kind`; ``HUDItemPlacement/off`` when the layout has
    /// nothing to say about it.
    public func placement(for kind: HUDItemKind) -> HUDItemPlacement {
        placements[kind] ?? .off
    }

    public mutating func set(_ placement: HUDItemPlacement, for kind: HUDItemKind) {
        placements[kind] = placement
    }

    // MARK: - Queries

    /// The items to draw on `side` at `presentation`, in the canonical order.
    ///
    /// The visibility rule lives here and nowhere else: an item shows once the
    /// HUD has opened at least as far as the stage it was given.
    public func items(
        on side: HUDItemSide,
        at presentation: HUDPresentation
    ) -> [HUDItemKind] {
        HUDItemKind.allCases.filter { kind in
            let placement = placement(for: kind)
            return placement.isEnabled
                && placement.side == side
                && presentation >= placement.stage
        }
    }

    /// Every item visible at `presentation`, both sides, left first.
    public func items(at presentation: HUDPresentation) -> [HUDItemKind] {
        items(on: .left, at: presentation) + items(on: .right, at: presentation)
    }

    /// The widest stage any enabled item asks for.
    ///
    /// Used to tell the user, in the settings, when a stage they have opened up
    /// would show nothing — a HUD configured with every item at `.expanded` has
    /// a peek that is indistinguishable from its parked state, and that is
    /// worth saying out loud rather than leaving them to discover.
    public func hasItems(at presentation: HUDPresentation) -> Bool {
        !items(at: presentation).isEmpty
    }

    // MARK: - Storage

    /// One item per string, `kind:side:stage:on|off`, so the whole layout is a
    /// plain `[String]` in `UserDefaults` that a person can read in
    /// `defaults read`.
    ///
    /// Switched-off items are written too, with their side and stage intact.
    /// Leaving them out would have been shorter, and would have meant that
    /// turning a readout off and on again silently discarded where the user had
    /// put it — a switch that quietly resets two other controls is a trap.
    ///
    /// Absence still means off. That is what an item introduced by a later
    /// release looks like in an older stored layout, and it must stay readable.
    public var storageValues: [String] {
        placements.keys.sorted { $0.rawValue < $1.rawValue }.map { kind in
            let placement = placement(for: kind)
            let flag = placement.isEnabled ? "on" : "off"
            return "\(kind.rawValue):\(placement.side.rawValue):\(placement.stage.rawValue):\(flag)"
        }
    }

    /// Rebuild a layout from ``storageValues``.
    ///
    /// Malformed entries are skipped rather than failing the parse: the stored
    /// value is a list of independent decisions, and one unreadable line is no
    /// reason to throw away the rest of somebody's configuration.
    ///
    /// A `nil` list — nothing stored yet — is the default layout. An **empty**
    /// list is not: that is a user who switched every item off, and it must
    /// survive a relaunch.
    public init?(storageValues: [String]?) {
        guard let storageValues else { return nil }
        // The stored list is the complete truth: anything it does not mention
        // is off, which ``placement(for:)`` already answers for an absent key.
        var placements: [HUDItemKind: HUDItemPlacement] = [:]
        for value in storageValues {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            // A three-part entry has no flag and means "on": that is the short
            // hand-written form, and it is what someone editing `defaults` by
            // hand will reach for.
            guard parts.count == 3 || parts.count == 4,
                  let side = HUDItemSide(rawValue: String(parts[1])),
                  let stage = HUDPresentation(rawValue: String(parts[2]))
            else { continue }
            let isEnabled = parts.count == 3 || parts[3] == "on"
            placements[HUDItemKind(rawValue: String(parts[0]))] = HUDItemPlacement(
                isEnabled: isEnabled,
                side: side,
                stage: stage
            )
        }
        self.init(placements: placements)
    }
}

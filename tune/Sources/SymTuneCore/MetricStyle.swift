import Foundation

// MARK: - Per-metric display style

/// How one metric is rendered in the menu bar.
///
/// The status item is a few dozen points of shared screen space, and what
/// belongs there differs per person: some want `CPU 12%`, some a glyph and a
/// bare number, some the full `17.0 GB`. Each axis below is independent so the
/// combinations do not have to be enumerated.
/// Which multiple a byte count is divided by before it is given a `GB`/`MB`
/// suffix.
///
/// macOS is not consistent here and neither can we be: Finder, System
/// Settings › Storage and every drive vendor count storage in powers of 1000,
/// while Activity Monitor counts memory in powers of 1024. Following each
/// surface's own convention is what makes a Tune reading match the number the
/// user can check it against — using 1024 for storage reports a disk as ~7%
/// emptier than System Settings does, which is a 33 GB lie on a 500 GB disk.
public enum ByteUnitConvention: Sendable {
    /// Powers of 1024 — memory.
    case binary
    /// Powers of 1000 — storage.
    case decimal

    public var gigabyte: Double { self == .binary ? 1_073_741_824 : 1_000_000_000 }
    public var megabyte: Double { self == .binary ? 1_048_576 : 1_000_000 }
}

public struct MetricStyle: Equatable, Sendable {
    /// What precedes the value.
    public enum LabelStyle: String, CaseIterable, Sendable {
        /// A short word: `CPU`, `RAM`, `Disk`, `Net`.
        case text
        /// An SF Symbol glyph.
        case icon
        /// Nothing — just the number.
        case hidden
    }

    /// Whether the value is an amount, a share of the total, or both.
    ///
    /// Not every metric has a total: CPU is inherently a percentage and
    /// network throughput has nothing to divide by, so those ignore anything
    /// but `absolute`.
    public enum ValueScale: String, CaseIterable, Sendable {
        case absolute
        case relative
        /// `442 GB · 89%` — the amount with its share appended. Costs the most
        /// menu-bar width, which is why it is not the default.
        case both
    }

    /// How much unit suffix the value carries.
    public enum UnitStyle: String, CaseIterable, Sendable {
        /// `17.0G`, `12%`, `1.2M`
        case abbreviated
        /// `17.0 GB`, `12%`, `1.2 MB/s`
        case full
        /// `17.0`, `12`, `1.2` — no suffix at all.
        case hidden
    }

    /// Which side of a used/free split the value reports.
    ///
    /// Not every metric has a free side to report: CPU and network have no
    /// meaningful "free" quantity, so those ignore `basis` the same way they
    /// ignore `scale`.
    public enum MetricBasis: String, CaseIterable, Sendable {
        /// What is occupied — the format the status item has always used.
        case used
        /// What is still available.
        case free
    }

    public var label: LabelStyle
    public var scale: ValueScale
    public var unit: UnitStyle
    public var basis: MetricBasis

    public init(
        label: LabelStyle = .text,
        scale: ValueScale = .absolute,
        unit: UnitStyle = .abbreviated,
        basis: MetricBasis = .used
    ) {
        self.label = label
        self.scale = scale
        self.unit = unit
        self.basis = basis
    }

    /// What every metric renders as until the user changes it — the format the
    /// status item used before per-metric styles existed.
    public static let `default` = MetricStyle()
}

extension MetricIdentifier {
    /// Short word shown when ``MetricStyle/LabelStyle/text`` is selected. Kept
    /// shorter than ``displayName`` because it competes for menu-bar width.
    public var statusItemLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .disk: return "Disk"
        case .network: return "Net"
        default: return rawValue.uppercased()
        }
    }

    /// SF Symbol shown when ``MetricStyle/LabelStyle/icon`` is selected.
    public var statusItemSymbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "arrow.up.arrow.down"
        default: return "gauge"
        }
    }

    /// Which byte-unit convention this metric's amounts are counted in.
    /// See ``ByteUnitConvention``.
    public var byteUnitConvention: ByteUnitConvention {
        self == .disk ? .decimal : .binary
    }

    /// Whether ``MetricStyle/ValueScale/relative`` means anything here.
    /// CPU is already a percentage; network throughput has no total to divide
    /// by. For those the scale control is inert and the UI disables it.
    public var supportsRelativeScale: Bool {
        self == .memory || self == .disk
    }

    /// Whether ``MetricStyle/MetricBasis/free`` means anything here.
    /// CPU and network have no free side to report, so `basis` is inert for
    /// them the same way `scale` is — a UI control for it should disable
    /// on the same basis.
    public var supportsBasis: Bool {
        self == .memory || self == .disk
    }
}

// MARK: - Status item segments

/// One piece of the rendered status-item title.
///
/// The status item is built as an `NSAttributedString` so an icon label can be
/// a real SF Symbol attachment rather than an approximation in Unicode. This
/// type keeps that rendering decision in the app layer while the formatting
/// logic — which is what actually needs testing — stays here.
public enum StatusItemSegment: Equatable, Sendable {
    /// Literal text, drawn in the status item's normal font.
    case text(String)
    /// An SF Symbol to draw inline, by symbol name.
    case symbol(String)
}

/// ISO-8601 calendar-week formatting shared by the menu-bar pipeline and tests.
///
/// ISO weeks begin on Monday and week 1 is the week containing the first
/// Thursday. The menu-bar form intentionally has no zero padding: `KW 1`, not
/// `KW 01`.
public enum CalendarWeekFormatting {
    /// Return an ISO-8601 calendar configured for the requested local timezone.
    public static func iso8601Calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Format the week containing `date` as `KW <n>`.
    public static func text(for date: Date, timeZone: TimeZone = .current) -> String {
        let week = iso8601Calendar(timeZone: timeZone).component(.weekOfYear, from: date)
        return "KW \(week)"
    }

    /// Build the text segment used by the existing status-item pipeline.
    public static func segment(for date: Date, timeZone: TimeZone = .current) -> StatusItemSegment {
        .text(text(for: date, timeZone: timeZone))
    }
}

// MARK: - Formatting

/// Turns a metrics report into styled status-item segments.
public enum MetricStyleFormatting {

    /// Build the status-item segments for `identifiers`, in order.
    ///
    /// Metrics without data are skipped entirely rather than rendered as a
    /// placeholder — a menu bar reading `RAM --` is worse than one metric less.
    public static func statusItemSegments(
        report: SystemMetricsReport,
        identifiers: [MetricIdentifier],
        styles: [MetricIdentifier: MetricStyle] = [:]
    ) -> [StatusItemSegment] {
        var segments: [StatusItemSegment] = []

        for id in identifiers {
            let style = styles[id] ?? .default
            guard let value = valueText(id, report: report, style: style) else { continue }

            if !segments.isEmpty {
                segments.append(.text("  "))
            }

            switch style.label {
            case .text:
                segments.append(.text("\(id.statusItemLabel) \(value)"))
            case .icon:
                segments.append(.symbol(id.statusItemSymbol))
                segments.append(.text(" \(value)"))
            case .hidden:
                segments.append(.text(value))
            }
        }

        return segments
    }

    /// A fixed, plausible reading used to preview a style choice.
    ///
    /// A live reading would make the preview flicker while the user is reading
    /// it, and would show nothing at all for a metric with no data.
    /// 42% CPU, 8 GB of 16 GB memory, 256 GB of 512 GB disk, 2 MB/s down.
    /// The disk figures are round in decimal GB — the convention storage is
    /// counted in — so the preview reads `256.0 GB`, not `238.4 GB`.
    public static let sampleReport = SystemMetricsReport(
        cpu: CPUReport(totalUtilization: 0.42, perCoreUtilization: []),
        memory: MemoryReport(
            usedBytes: 8_589_934_592,
            freeBytes: 8_589_934_592,
            wiredBytes: nil,
            compressedBytes: nil,
            pressure: nil
        ),
        disk: DiskReport(
            capacityBytes: 512_000_000_000,
            usedBytes: 256_000_000_000,
            freeBytes: 256_000_000_000
        ),
        network: NetworkReport(
            interfaces: [],
            aggregateBytesIn: 0,
            aggregateBytesOut: 0,
            aggregateBytesInPerSecond: 2_097_152,
            aggregateBytesOutPerSecond: 524_288
        )
    )

    /// Flatten segments to plain text, with symbols rendered as their label.
    /// Used where an attributed string is not available (accessibility
    /// descriptions, `symtune status` output, tests).
    public static func plainText(_ segments: [StatusItemSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text
            case .symbol: return ""
            }
        }.joined()
    }

    // MARK: Per-metric values

    static func valueText(
        _ id: MetricIdentifier,
        report: SystemMetricsReport,
        style: MetricStyle
    ) -> String? {
        switch id {
        case .cpu:
            guard let utilization = report.cpu.totalUtilization else { return nil }
            return percent(utilization * 100, style: style)

        case .memory:
            guard let used = report.memory.usedBytes else { return nil }
            let free = report.memory.freeBytes
            guard let amount = style.basis == .free ? free : used else { return nil }
            return amountText(
                Double(amount),
                total: free.map { Double(used + $0) },
                style: style,
                convention: id.byteUnitConvention
            )

        case .disk:
            guard let disk = report.disk else { return nil }
            let amount = style.basis == .free ? disk.freeBytes : disk.usedBytes
            return amountText(
                Double(amount),
                total: disk.capacityBytes > 0 ? Double(disk.capacityBytes) : nil,
                style: style,
                convention: id.byteUnitConvention
            )

        case .network:
            let down = report.network.aggregateBytesInPerSecond
            let up = report.network.aggregateBytesOutPerSecond
            guard down != nil || up != nil else { return nil }
            var text = ""
            if let down { text += "\u{2193}\(rate(down, style: style))" }
            if let up {
                if !text.isEmpty { text += " " }
                text += "\u{2191}\(rate(up, style: style))"
            }
            return text

        default:
            return nil
        }
    }

    // MARK: Unit rendering

    /// One byte amount rendered per ``MetricStyle/ValueScale``: the amount,
    /// its share of `total`, or both.
    ///
    /// A share needs a total, so a `.relative` request without one has no
    /// answer and returns `nil` (the metric is then skipped rather than shown
    /// as a placeholder); `.both` degrades to the amount alone instead, since
    /// it did ask for that much.
    private static func amountText(
        _ amount: Double,
        total: Double?,
        style: MetricStyle,
        convention: ByteUnitConvention
    ) -> String? {
        switch style.scale {
        case .absolute:
            return bytes(amount, style: style, convention: convention)
        case .relative:
            return total.map { percent(amount / $0 * 100, style: style) }
        case .both:
            let absolute = bytes(amount, style: style, convention: convention)
            // In `.both` the percentage sits next to another number, so it
            // keeps its sign even when the unit style is `.hidden` — two bare
            // numbers side by side are unreadable.
            guard let total else { return absolute }
            return absolute + " · " + percent(amount / total * 100, style: style, forceSign: true)
        }
    }

    /// Two-digit padded, as the status item always has been: an unpadded
    /// percentage makes the whole menu-bar title shift left every time CPU
    /// crosses 10%.
    private static func percent(_ value: Double, style: MetricStyle, forceSign: Bool = false) -> String {
        let number = String(format: "%2d", Int(value.rounded()))
        return style.unit == .hidden && !forceSign ? number : number + "%"
    }

    private static func bytes(_ value: Double, style: MetricStyle, convention: ByteUnitConvention) -> String {
        let gigabyte = convention.gigabyte
        let megabyte = convention.megabyte

        if value >= gigabyte {
            let number = String(format: "%.1f", value / gigabyte)
            switch style.unit {
            case .abbreviated: return number + "G"
            case .full: return number + " GB"
            case .hidden: return number
            }
        }

        let number = String(format: "%.0f", value / megabyte)
        switch style.unit {
        case .abbreviated: return number + "M"
        case .full: return number + " MB"
        case .hidden: return number
        }
    }

    private static func rate(_ bytesPerSecond: Double, style: MetricStyle) -> String {
        let megabyte = 1_048_576.0
        let kilobyte = 1_024.0

        if bytesPerSecond >= megabyte {
            let number = String(format: "%.1f", bytesPerSecond / megabyte)
            switch style.unit {
            case .abbreviated: return number + "M"
            case .full: return number + " MB/s"
            case .hidden: return number
            }
        }
        if bytesPerSecond >= kilobyte {
            let number = String(format: "%.0f", bytesPerSecond / kilobyte)
            switch style.unit {
            case .abbreviated: return number + "K"
            case .full: return number + " KB/s"
            case .hidden: return number
            }
        }
        let number = String(format: "%.0f", bytesPerSecond)
        switch style.unit {
        case .abbreviated: return number + "B"
        case .full: return number + " B/s"
        case .hidden: return number
        }
    }
}

// MARK: - Popover cards

/// A card in the status popover that the user can turn off.
///
/// The header and footer are not listed: they are the panel's own chrome, not
/// content, and hiding them would leave no way back to Preferences.
public struct PopoverCard: RawRepresentable, Hashable, Codable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let displayControls = PopoverCard(rawValue: "display_controls")
    public static let keepAwake = PopoverCard(rawValue: "keep_awake")
    public static let fanControl = PopoverCard(rawValue: "fan_control")
    public static let systemStatus = PopoverCard(rawValue: "system_status")
    public static let topProcesses = PopoverCard(rawValue: "top_processes")
    public static let metricsHistory = PopoverCard(rawValue: "metrics_history")
    public static let displays = PopoverCard(rawValue: "displays")

    public static var allCases: [PopoverCard] {
        [.displayControls, .keepAwake, .fanControl, .systemStatus, .topProcesses,
         .metricsHistory, .displays]
    }

    public var displayName: String {
        switch self {
        case .displayControls: return "Display Controls"
        case .keepAwake: return "Keep Awake"
        case .fanControl: return "Fan Control"
        case .systemStatus: return "System Status"
        case .topProcesses: return "Top Processes"
        case .metricsHistory: return "System Metrics"
        case .displays: return "Connected Displays"
        default: return rawValue
        }
    }

    /// Whether this card is worth showing when the hardware cannot back it.
    ///
    /// Fan Control on a fanless Mac is a permanent "Not available on this Mac"
    /// notice; it costs panel height every time the popover opens and tells the
    /// user nothing new after the first look. Cards like this default to hidden
    /// when their hardware is missing, and the user can still turn them on.
    public var hidesWhenHardwareMissing: Bool {
        self == .fanControl
    }
}

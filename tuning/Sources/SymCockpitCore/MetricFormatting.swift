import Foundation

/// Shared metric formatting.
///
/// The status item and the history card used to carry near-identical copies of
/// these formatters and ran them inside SwiftUI body evaluations. They now live
/// in one place and are called once per refresh.
public enum MetricFormatting {

    // MARK: - Availability

    public static func hasData(_ id: MetricIdentifier, report: SystemMetricsReport) -> Bool {
        switch id {
        case .cpu: return report.cpu.totalUtilization != nil
        case .memory: return report.memory.usedBytes != nil
        case .disk: return report.disk != nil
        case .network:
            return report.network.aggregateBytesInPerSecond != nil
                || report.network.aggregateBytesOutPerSecond != nil
        default: return false
        }
    }

    // MARK: - History card

    /// Format an aggregated history value for the metrics card.
    ///
    /// The value handed in is always a "used" quantity — that is what the
    /// history ring buffers record — so a `style.basis == .free` request is
    /// honoured by converting before formatting. The two byte metrics store
    /// different things, and `totalBytes` is what bridges them:
    ///
    /// - `.memory` stores raw used bytes, so `totalBytes` (used + free,
    ///   effectively constant for a running session) yields both the free
    ///   amount and the percentage.
    /// - `.disk` stores a used *percentage*, so `totalBytes` (the volume's
    ///   capacity) is what turns it back into gigabytes.
    ///
    /// Without `totalBytes` neither conversion is possible, and the value is
    /// rendered in whatever form it was stored — the same way
    /// ``MetricStyleFormatting`` treats data it cannot honour a style against.
    public static func value(
        _ id: MetricIdentifier,
        _ value: Double,
        style: MetricStyle = .default,
        totalBytes: UInt64? = nil
    ) -> String {
        switch id {
        case .cpu:
            return String(format: "%.0f%%", value)
        case .disk:
            let usedShare = style.basis == .free ? (100 - value) : value
            guard let totalBytes, totalBytes > 0 else { return percentText(usedShare) }
            return amountText(
                usedShare / 100 * Double(totalBytes),
                share: usedShare,
                style: style,
                convention: id.byteUnitConvention
            )
        case .memory:
            let displayed: Double
            if style.basis == .free, let totalBytes {
                displayed = Double(totalBytes) - value
            } else {
                displayed = value
            }
            let share = totalBytes.flatMap { $0 > 0 ? displayed / Double($0) * 100 : nil }
            return amountText(displayed, share: share, style: style, convention: id.byteUnitConvention)
        case .network:
            return netRate(value)
        default:
            return String(format: "%.1f", value)
        }
    }

    /// One reading rendered per ``MetricStyle/ValueScale``: the amount, its
    /// share of the total, or both.
    ///
    /// Unlike the menu bar this card is not fighting for width, so units are
    /// always spelled out and percentages are not padded. A `.relative` or
    /// `.both` request without a `share` falls back to the amount — the card
    /// showing gigabytes is better than the card showing nothing.
    private static func amountText(
        _ amount: Double,
        share: Double?,
        style: MetricStyle,
        convention: ByteUnitConvention
    ) -> String {
        let absolute = byteText(amount, convention: convention)
        guard let share else { return absolute }
        switch style.scale {
        case .absolute: return absolute
        case .relative: return percentText(share)
        case .both: return absolute + " · " + percentText(share)
        }
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private static func byteText(_ value: Double, convention: ByteUnitConvention) -> String {
        if value >= convention.gigabyte {
            return String(format: "%.1f GB", value / convention.gigabyte)
        }
        return String(format: "%.0f MB", value / convention.megabyte)
    }

    /// Value shown before enough history exists for min/max, or `nil` when the
    /// metric has no data at all.
    ///
    /// Honours `style.basis` the same way ``MetricStyleFormatting/valueText``
    /// does for the status item, so this reading — the popover's fallback
    /// display and the "current" figure once history exists — never
    /// contradicts the menu-bar title directly above it.
    public static func fallbackValue(
        _ id: MetricIdentifier,
        report: SystemMetricsReport,
        style: MetricStyle = .default
    ) -> String? {
        switch id {
        case .cpu:
            guard let utilization = report.cpu.totalUtilization else { return nil }
            return String(format: "%.0f%%", utilization * 100)
        case .memory:
            guard let used = report.memory.usedBytes else { return nil }
            let free = report.memory.freeBytes
            guard let amount = style.basis == .free ? free : used else { return nil }
            let total = free.map { used + $0 }
            return amountText(
                Double(amount),
                share: total.flatMap { $0 > 0 ? Double(amount) / Double($0) * 100 : nil },
                style: style,
                convention: id.byteUnitConvention
            )
        case .disk:
            guard let disk = report.disk, disk.capacityBytes > 0 else { return nil }
            let amount = style.basis == .free ? disk.freeBytes : disk.usedBytes
            return amountText(
                Double(amount),
                share: Double(amount) / Double(disk.capacityBytes) * 100,
                style: style,
                convention: id.byteUnitConvention
            )
        case .network:
            let down = report.network.aggregateBytesInPerSecond
            let up = report.network.aggregateBytesOutPerSecond
            guard down != nil || up != nil else { return nil }
            return netRate((down ?? 0) + (up ?? 0))
        default:
            return nil
        }
    }

    /// Formatted current/minimum/maximum figures for a metrics-history row.
    public struct HistoryRowValues: Equatable {
        public let current: String
        public let minimum: String
        public let maximum: String
    }

    /// Current/minimum/maximum for a metrics-history row, honouring
    /// `style.basis`.
    ///
    /// The ring buffer always records a "used" quantity, so switching to
    /// `.free` both converts each figure (see ``value(_:_:style:totalBytes:)``)
    /// and swaps which raw sample backs "minimum" and "maximum": the sample
    /// with the least usage is the one with the most free space, and vice
    /// versa. Pass `totalBytes` for both byte metrics — used + free for
    /// `.memory` (assumed effectively constant across the session), the
    /// volume capacity for `.disk` — so amounts and percentages are both
    /// derivable; see ``value(_:_:style:totalBytes:)``.
    public static func historyRowValues(
        _ id: MetricIdentifier,
        stats: MetricStats,
        style: MetricStyle,
        totalBytes: UInt64? = nil
    ) -> HistoryRowValues {
        guard style.basis == .free else {
            return HistoryRowValues(
                current: value(id, stats.current, style: style, totalBytes: totalBytes),
                minimum: value(id, stats.min, style: style, totalBytes: totalBytes),
                maximum: value(id, stats.max, style: style, totalBytes: totalBytes)
            )
        }
        return HistoryRowValues(
            current: value(id, stats.current, style: style, totalBytes: totalBytes),
            minimum: value(id, stats.max, style: style, totalBytes: totalBytes),
            maximum: value(id, stats.min, style: style, totalBytes: totalBytes)
        )
    }

    /// Human-readable byte size (`"1.8 GB"`, `"482 MB"`, `"96 KB"`).
    /// Shared by the CLI process listing and the popover's process card so both
    /// round the same way.
    public static func bytes(_ value: UInt64) -> String {
        let bytes = Double(value)
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        }
        if bytes >= 1_048_576 {
            return String(format: "%.0f MB", bytes / 1_048_576)
        }
        if bytes >= 1_024 {
            return String(format: "%.0f KB", bytes / 1_024)
        }
        return "\(value) B"
    }

    /// Decimal sizes for mounted storage, matching Finder rather than RAM.
    public static func storageBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }

    private static func netRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576.0)
        }
        if bytesPerSecond >= 1_024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_024.0)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    // MARK: - Status item

    /// Compact single-line status-item text. Returns `""` when no selected
    /// metric has data, which tells the status item to fall back to its icon.
    public static func statusItemText(
        report: SystemMetricsReport,
        identifiers: [MetricIdentifier]
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(identifiers.count)

        for id in identifiers {
            switch id {
            case .cpu:
                if let utilization = report.cpu.totalUtilization {
                    parts.append("CPU \(String(format: "%2d%%", Int(utilization * 100)))")
                }
            case .memory:
                if let used = report.memory.usedBytes {
                    parts.append("RAM \(compactBytes(used))")
                }
            case .disk:
                if let disk = report.disk {
                    let gigabytes = Double(disk.usedBytes) / MetricIdentifier.disk.byteUnitConvention.gigabyte
                    parts.append(String(format: "💾%.0fG", gigabytes))
                }
            case .network:
                let down = report.network.aggregateBytesInPerSecond
                let up = report.network.aggregateBytesOutPerSecond
                guard down != nil || up != nil else { continue }
                var text = ""
                if let down { text += "↓\(compactRate(down))" }
                if let up {
                    if !text.isEmpty { text += " " }
                    text += "↑\(compactRate(up))"
                }
                parts.append(text)
            default:
                continue
            }
        }

        return parts.joined(separator: "  ")
    }

    private static func compactBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1fG", Double(bytes) / 1_073_741_824.0)
        }
        return String(format: "%.0fM", Double(bytes) / 1_048_576.0)
    }

    private static func compactRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1fM", bytesPerSecond / 1_048_576.0)
        }
        if bytesPerSecond >= 1_024 {
            return String(format: "%.0fK", bytesPerSecond / 1_024.0)
        }
        return String(format: "%.0fB", bytesPerSecond)
    }

    // MARK: - HUD shoulder

    /// The short form of a readout string, for the resting notch shoulder
    /// (issue #374).
    ///
    /// A parked shoulder is a few dozen points wide, so the long strings the
    /// card uses (`485.0 GB`, `100 %`) are rewritten rather than squeezed:
    ///
    /// - an amount keeps at most three significant digits — `485.0 GB` becomes
    ///   `485 GB`, `15.2 GB` becomes `15 GB`, `7.9 GB` stays `7.9 GB`;
    /// - the unit stays as it is (`GB`, `MB/s`): a bare `G` read as an
    ///   abbreviation nobody uses for storage;
    /// - number and unit (including a percent sign) are separated by
    ///   ``unitGap``, a narrow no-break space: a full space costs width the
    ///   shoulder does not have, and none at all runs the digits into the unit.
    ///
    /// Anything else (`KW 37`, `Awake`) is returned untouched, so the function
    /// is safe to apply to any HUD value. It is display-only: the accessibility
    /// label and the expanded card keep the full text.
    /// The gap between a number and its unit in ``compactReadout(_:)``: U+202F
    /// NARROW NO-BREAK SPACE.
    public static let unitGap = "\u{202F}"

    public static func compactReadout(_ text: String) -> String {
        // A size or rate with its unit: `15.2 GB`, `512 MB`, `1.2 MB/s`. Built
        // here rather than held in a static: `Regex` is not `Sendable`.
        let sizeToken = #/(\d+(?:\.\d+)?) ?(TB|GB|MB|KB|B)(/s)?/#
        return text
            .replacing(sizeToken) { match in
                compactAmount(match.output.1)
                    + unitGap
                    + String(match.output.2)
                    + (match.output.3.map { String($0) } ?? "")
            }
            .replacing(#/(\d) ?%/#) { match in "\(match.output.1)\(unitGap)%" }
    }

    private static func compactAmount(_ digits: Substring) -> String {
        guard let amount = Double(digits) else { return String(digits) }
        if amount >= 10 { return String(Int(amount.rounded())) }
        // Below ten one decimal carries information (`7.9 GB`), unless it is a
        // zero (`8.0` → `8`).
        let tenths = (amount * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}

import Foundation

// MARK: - AI usage formatting

/// Human-readable formatting for AI usage meters and countdowns.
///
/// Pure functions so the popover card and the status item stay thin and the
/// wording is unit-tested once, here.
public enum AIUsageFormatting {
    /// Compact reset countdown: `2d 4h`, `3h 05m`, `12m`, `45s`, or
    /// `—` when no reset time is known.
    public static func countdownText(until resetDate: Date?, now: Date = Date()) -> String {
        guard let resetDate else { return "—" }
        let remaining = max(0, resetDate.timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded())
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }

    /// The remaining amount of a meter, e.g. `1834 of 2048 requests`,
    /// `$42.50 of $100.00`, or `12% left`. Falls back to the used amount
    /// when no limit is known.
    public static func remainingText(for meter: AIUsageMeter) -> String {
        guard let limit = meter.limit else {
            if let used = meter.used {
                return "\(amountText(used, unit: meter.unit)) used"
            }
            return "—"
        }
        let remaining = (meter.used.map { limit - $0 }) ?? limit
        switch meter.unit {
        case .percent:
            return "\(percentText(remaining))% left"
        case .currency:
            return "\(currencyText(remaining)) of \(currencyText(limit)) left"
        case .tokens, .requests, .credits:
            return "\(plainText(remaining)) of \(plainText(limit)) \(meter.unit.unitLabel) left"
        }
    }

    /// Progress fraction (0…1) for a meter, or `nil` when it cannot be
    /// expressed (no used value).
    public static func progressFraction(for meter: AIUsageMeter) -> Double? {
        guard let used = meter.used else { return nil }
        switch meter.unit {
        case .percent:
            // Percent meters are already 0…100 (used fraction of a 100 cap).
            return min(1, max(0, NSDecimalNumber(decimal: used).doubleValue / 100))
        default:
            guard let limit = meter.limit, limit > 0 else { return nil }
            let usedDouble = NSDecimalNumber(decimal: used).doubleValue
            let limitDouble = NSDecimalNumber(decimal: limit).doubleValue
            return min(1, max(0, usedDouble / limitDouble))
        }
    }

    /// Compact status-item text for a provider's primary meter: the used
    /// percent (e.g. `42%`), or `—` when nothing is readable.
    public static func statusItemText(for snapshot: AIUsageSnapshot?) -> String {
        guard let snapshot, let meter = snapshot.meters.first else { return "—" }
        switch meter.unit {
        case .percent:
            return "\(percentText(meter.used ?? 0))%"
        case .currency:
            return currencyText(meter.used ?? 0)
        case .tokens, .requests, .credits:
            return plainText(meter.used ?? 0)
        }
    }

    // MARK: - Internals

    static func percentText(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "%.0f", double.rounded())
    }

    private static func currencyText(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", double / 100)
    }

    private static func plainText(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        if double == double.rounded() {
            return String(format: "%.0f", double)
        }
        return String(format: "%.2f", double)
    }

    private static func amountText(_ value: Decimal, unit: AIUsageUnit) -> String {
        switch unit {
        case .currency:
            return currencyText(value)
        default:
            return plainText(value)
        }
    }
}

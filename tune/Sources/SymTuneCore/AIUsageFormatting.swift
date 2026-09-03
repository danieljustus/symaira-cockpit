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
        case .currency(let code):
            return "\(currencyText(remaining, code: code)) of \(currencyText(limit, code: code)) left"
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
    ///
    /// A provider that reports no meters at all but does report a balance —
    /// a credit account rather than a quota — falls back to that balance, so
    /// the readout is blank only when there is genuinely nothing to say.
    public static func statusItemText(for snapshot: AIUsageSnapshot?) -> String {
        guard let snapshot else { return "—" }
        guard let meter = snapshot.meters.first else {
            guard let balance = snapshot.balance else { return "—" }
            return currencyText(balance, code: snapshot.currency ?? "USD")
        }
        switch meter.unit {
        case .percent:
            return "\(percentText(meter.used ?? 0))%"
        case .currency(let code):
            return currencyText(meter.used ?? 0, code: code)
        case .tokens, .requests, .credits:
            return plainText(meter.used ?? 0)
        }
    }

    /// A provider's balance line, e.g. `Balance: $12.40` — or `nil` when it
    /// reports none.
    public static func balanceText(for snapshot: AIUsageSnapshot) -> String? {
        guard let balance = snapshot.balance else { return nil }
        return "Balance: " + currencyText(balance, code: snapshot.currency ?? "USD")
    }

    /// Why a successful fetch produced nothing to show. A provider can answer
    /// with no quota at all (an unlimited plan, or one whose account type
    /// exposes no meter), and that has to read as an answer rather than as an
    /// empty box that looks like a broken card.
    public static func emptySnapshotText(for snapshot: AIUsageSnapshot) -> String? {
        guard snapshot.meters.isEmpty, snapshot.balance == nil else { return nil }
        return "No quota reported for this account."
    }

    // MARK: - Internals

    static func percentText(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "%.0f", double.rounded())
    }

    /// Amounts arrive in the currency's major unit — symbrain passes each
    /// provider's own figure through unscaled, and every provider that
    /// reports money reports it in whole currency (OpenRouter's `usage` and
    /// `limit` are dollars, not cents). Rendering assumed cents here, which
    /// divided every spend figure by 100.
    private static func currencyText(_ value: Decimal, code: String) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        if let symbol = currencySymbols[code.uppercased()] {
            return String(format: "%@%.2f", symbol, double)
        }
        return String(format: "%.2f %@", double, code)
    }

    private static let currencySymbols = ["USD": "$", "EUR": "€", "GBP": "£"]

    private static func plainText(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        if double == double.rounded() {
            return String(format: "%.0f", double)
        }
        return String(format: "%.2f", double)
    }

    private static func amountText(_ value: Decimal, unit: AIUsageUnit) -> String {
        switch unit {
        case .currency(let code):
            return currencyText(value, code: code)
        default:
            return plainText(value)
        }
    }
}

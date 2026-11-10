import Foundation

/// Presentation-only customization; no credentials, fetching or inferred window durations.
public struct AIUsageLayout: Codable, Equatable, Sendable {
    public var remaining = true
    public var absoluteReset = false
    public var bars = false
    public var pins: [String: [String]] = [:]
    public var metricOrder: [String: [String]] = [:]
    public var hidden: Set<String> = []
    public var onDemand: Set<String> = []
    public var expanded: Set<String> = []

    public init() {}

    @discardableResult
    public mutating func togglePin(_ id: String, provider: String) -> Bool {
        var selected = Self.ordered(pins[provider] ?? [], available: pins[provider] ?? [])
        if selected.contains(id) {
            selected.removeAll { $0 == id }
        } else {
            guard selected.count < 2 else { return false }
            selected.append(id)
        }
        pins[provider] = selected
        return true
    }

    public static func ordered(_ saved: [String], available: [String]) -> [String] {
        var seen: Set<String> = []
        let allowed = Set(available)
        return (saved + available).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    public static func moving(_ id: String, before target: String, in order: [String]) -> [String] {
        guard id != target, order.contains(id), order.contains(target) else { return order }
        var result = order.filter { $0 != id }
        result.insert(id, at: result.firstIndex(of: target)!)
        return result
    }
}

public struct AIUsageMetric: Identifiable, Equatable, Sendable {
    public let id: String
    public let meter: AIUsageMeter
    public let isBalance: Bool

    public init(id: String, meter: AIUsageMeter, isBalance: Bool = false) {
        self.id = id
        self.meter = meter
        self.isBalance = isBalance
    }

    public static func metrics(snapshot: AIUsageSnapshot) -> [Self] {
        var result = metrics(provider: snapshot.providerID, meters: snapshot.meters)
        if let balance = snapshot.balance {
            result.append(Self(id: "balance:\(snapshot.providerID)",
                meter: AIUsageMeter(label: "Balance", used: balance, unit: .currency(snapshot.currency ?? "USD")),
                isBalance: true))
        }
        return result
    }

    /// Exact duplicate rows collapse. Repeated labels get an occurrence suffix;
    /// ponytail: indistinguishable repeated labels follow source order until Brain supplies stable IDs.
    public static func metrics(provider: String, meters: [AIUsageMeter]) -> [Self] {
        var unique: [AIUsageMeter] = []
        var occurrences: [String: Int] = [:]
        return meters.compactMap { meter in
            guard !unique.contains(meter) else { return nil }
            unique.append(meter)
            let occurrence = occurrences[meter.label, default: 0]
            occurrences[meter.label] = occurrence + 1
            let id = "\(provider.utf8.count):\(provider)\(meter.label.utf8.count):\(meter.label):\(occurrence)"
            return Self(id: id, meter: meter)
        }
    }

    public func value(remaining: Bool) -> String? {
        guard let used = meter.used else { return nil }
        let value: Decimal
        if remaining {
            let limit = meter.limit ?? (meter.unit == .percent ? 100 : nil)
            value = limit.map { max(0, $0 - used) } ?? used
        } else {
            value = used
        }
        let number = NSDecimalNumber(decimal: value).doubleValue
        switch meter.unit {
        case .currency(let code): return String(format: "%.2f %@", number, code)
        case .percent: return String(format: "%.0f%%", number)
        default: return "\(NSDecimalNumber(decimal: value).stringValue) \(meter.unit.unitLabel)"
        }
    }

    public func displayValue(remaining: Bool) -> String {
        guard let value = value(remaining: remaining) else { return "No data" }
        if isBalance { return value + " available" }
        let showsRemaining = remaining && (meter.limit != nil || meter.unit == .percent)
        return value + (showsRemaining ? " left" : " used")
    }

    public func fraction(remaining: Bool) -> Double? {
        guard let used = AIUsageFormatting.progressFraction(for: meter) else { return nil }
        return remaining ? 1 - used : used
    }

    public func reset(absolute: Bool, now: Date) -> String? {
        guard let date = meter.resetsAt else { return nil }
        return absolute
            ? "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
            : "Resets in \(AIUsageFormatting.countdownText(until: date, now: now))"
    }
}

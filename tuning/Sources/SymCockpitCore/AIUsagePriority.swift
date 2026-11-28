import Foundation

/// How close one bounded limit is to running out (#450).
public enum AIUsageSeverity: Int, Comparable, Sendable {
    case normal, warning, critical, usedUp

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AIUsageThresholds: Equatable, Sendable {
    /// Used fractions (0...1) at which a limit counts as warning and critical.
    public var warning: Double
    public var critical: Double

    public init(warning: Double = 0.8, critical: Double = 0.95) {
        self.warning = warning
        self.critical = max(warning, critical)
    }

    public func severity(usedFraction used: Double) -> AIUsageSeverity {
        if used >= 1 { return .usedUp }
        if used >= critical { return .critical }
        if used >= warning { return .warning }
        return .normal
    }
}

/// One bounded limit as the menu-bar priority strip and the alerts see it.
public struct AIUsagePriorityItem: Equatable, Sendable {
    public let providerID: String
    public let metricID: String
    public let usedFraction: Double
    public let resetsAt: Date?
    public let pinned: Bool

    public init(providerID: String, metricID: String, usedFraction: Double, resetsAt: Date? = nil, pinned: Bool = false) {
        self.providerID = providerID
        self.metricID = metricID
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.pinned = pinned
    }
}

/// The documented menu-bar order (#450): pinned limits in their given order, then
/// used-up, critical and warning limits, then "use it or lose it" limits (reset within
/// a day with less than half used). Within a group the most used comes first, then the
/// earliest reset. Other limits are not shown.
public enum AIUsagePriority {
    public static let useItOrLoseItWindow: TimeInterval = 24 * 60 * 60

    public static func isUseItOrLoseIt(_ item: AIUsagePriorityItem, now: Date) -> Bool {
        guard let reset = item.resetsAt else { return false }
        let left = reset.timeIntervalSince(now)
        return left > 0 && left <= useItOrLoseItWindow && item.usedFraction < 0.5
    }

    public static func ordered(_ items: [AIUsagePriorityItem], thresholds: AIUsageThresholds, now: Date) -> [AIUsagePriorityItem] {
        func rank(_ item: AIUsagePriorityItem) -> Int? {
            switch thresholds.severity(usedFraction: item.usedFraction) {
            case .usedUp: return 0
            case .critical: return 1
            case .warning: return 2
            case .normal: return isUseItOrLoseIt(item, now: now) ? 3 : nil
            }
        }
        let urgent = items.filter { !$0.pinned }.compactMap { item in rank(item).map { (item, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.usedFraction != b.0.usedFraction {
                    return a.1 == 3 ? a.0.usedFraction < b.0.usedFraction : a.0.usedFraction > b.0.usedFraction
                }
                return (a.0.resetsAt ?? .distantFuture) < (b.0.resetsAt ?? .distantFuture)
            }
            .map(\.0)
        return items.filter(\.pinned) + urgent
    }

    /// The first `count` of `ordered`, and how many urgent limits did not fit.
    public static func strip(_ items: [AIUsagePriorityItem], thresholds: AIUsageThresholds, now: Date,
                             count: Int) -> (shown: [AIUsagePriorityItem], overflow: Int) {
        let all = ordered(items, thresholds: thresholds, now: now)
        let shown = Array(all.prefix(max(0, count)))
        return (shown, all.count - shown.count)
    }
}

/// Remembers each limit's last severity and reports upward crossings into warning,
/// critical or used up. The first sighting of a limit only records it, so starting the
/// app never repeats an alert; a drop (for example after a reset) re-arms it.
public struct AIUsageQuotaAlerts: Sendable {
    public struct Alert: Equatable, Sendable {
        public let item: AIUsagePriorityItem
        public let severity: AIUsageSeverity
    }

    private var last: [String: AIUsageSeverity] = [:]

    public init() {}

    public mutating func evaluate(_ items: [AIUsagePriorityItem], thresholds: AIUsageThresholds) -> [Alert] {
        var alerts: [Alert] = []
        for item in items {
            let severity = thresholds.severity(usedFraction: item.usedFraction)
            if let previous = last[item.metricID], severity > previous {
                alerts.append(Alert(item: item, severity: severity))
            }
            // A limit missing from one round (a failed fetch) keeps its last state.
            last[item.metricID] = severity
        }
        return alerts
    }
}

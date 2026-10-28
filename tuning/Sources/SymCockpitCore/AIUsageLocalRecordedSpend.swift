import Foundation

/// Only explicitly consented local history participates; quota/balance snapshots cannot enter this calculation.
public struct AIUsageLocalRecordedSpend: Sendable, Equatable {
    public enum Period: String, CaseIterable, Sendable {
        case today, yesterday, last30Days = "last_30_days"
        public var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .last30Days: "30 Days"
            }
        }
    }
    public enum Mode: String, CaseIterable, Sendable {
        case cost, tokens, costPerMillion
        public var title: String {
            switch self {
            case .cost: "Cost"
            case .tokens: "Tokens"
            case .costPerMillion: "Cost / 1M"
            }
        }
    }
    public struct Contribution: Identifiable, Sendable, Equatable {
        public let id: String
        public let value: Decimal?
        public let detail: String
        public var includesEstimates = false
    }
    public let contributions: [Contribution]
    public let total: Decimal?
    public let message: String
    public let timezone: String?
    public let mode: Mode
    public let includesEstimates: Bool
    public var title: String { includesEstimates ? "Local Cost Overview · Recorded + Estimated · Unattributed" : "Local Recorded Spend · Unattributed" }

    public init(providerIDs: Set<String>, histories: [String: AIUsageRecordedHistory], period: Period, mode: Mode) {
        self.mode = mode
        let selected = providerIDs.intersection(["grok", "opencode", "claude", "codex"]).sorted()
        includesEstimates = selected.contains { id in
            histories[id]?.periods.first { $0.key == period.rawValue }?.models.contains { $0.estimatedCost != nil } == true
        }
        let calendars = Set(selected.compactMap { histories[$0]?.timezone })
        timezone = calendars.count == 1 ? calendars.first : nil
        let incompatible = calendars.count > 1
        contributions = selected.map { id in
            guard let history = histories[id] else {
                return Contribution(id: id, value: nil, detail: "History absent or invalid; refresh to retry")
            }
            guard !incompatible else { return Contribution(id: id, value: nil, detail: "Incompatible history calendars") }
            guard history.status == .available || (mode == .tokens && history.status == .partial), history.excludedEvents == 0 else {
                let state: String
                switch history.status {
                case .noData: state = "No recorded data — not zero"
                case .unavailable: state = "Local history unavailable; refresh to retry"
                case .partial, .available: state = "Incomplete recorded data"
                }
                let coverage = history.priceSnapshot != nil ? history.periods.first { $0.key == period.rawValue }.map { "; " + history.costDetail($0) } ?? "" : ""
                return Contribution(id: id, value: nil, detail: "\(state); \(history.excludedEvents) excluded events" + coverage,
                                    includesEstimates: history.includesEstimates)
            }
            guard let bucket = history.periods.first(where: { $0.key == period.rawValue }) else {
                return Contribution(id: id, value: nil, detail: "No recorded data for this period — not zero")
            }
            let cost = history.total(bucket, cost: true)
            let tokens = history.total(bucket, cost: false)
            let value: Decimal?
            let missing = bucket.models.reduce(0) { sum, row in
                sum + (mode == .cost ? row.missingCost : mode == .tokens ? row.missingTokens : row.missingCost + row.missingTokens)
            }
            switch mode {
            case .cost: value = cost
            case .tokens: value = tokens
            case .costPerMillion:
                if let cost, let tokens, tokens > 0 { value = cost * 1_000_000 / tokens } else { value = nil }
            }
            let detail = mode == .costPerMillion && tokens == 0 ? "Zero recorded tokens; rate undefined" :
                value == nil ? "Incomplete: \(missing) missing measurements; inspect model details" : "Complete \(history.costLabel(for: bucket)) local contribution"
            return Contribution(id: id, value: value, detail: detail + (history.priceSnapshot != nil ? "; " + history.costDetail(bucket) : ""),
                                includesEstimates: bucket.models.contains { $0.estimatedCost != nil })
        }
        if selected.isEmpty {
            total = nil
            message = "Local History Off. Enable a provider and its local-history consent in Customize."
        } else if contributions.contains(where: { contribution in
            guard contribution.value == nil else { return false }
            // A complete zero-token source has no individual rate, but can join a weighted total.
            guard mode == .costPerMillion, !incompatible, let history = histories[contribution.id],
                  let bucket = history.periods.first(where: { $0.key == period.rawValue }),
                  history.total(bucket, cost: true) != nil, history.total(bucket, cost: false) == 0 else { return true }
            return false
        }) {
            total = nil
            message = "Incomplete — no complete total. Missing or excluded data is not zero."
        } else if mode == .costPerMillion {
            // A combined rate is weighted by tokens, never the sum or mean of provider rates.
            var cost: Decimal = 0
            var tokens: Decimal = 0
            for id in selected {
                if let history = histories[id], let bucket = history.periods.first(where: { $0.key == period.rawValue }),
                   let providerCost = history.total(bucket, cost: true), let providerTokens = history.total(bucket, cost: false) {
                    cost += providerCost
                    tokens += providerTokens
                }
            }
            total = tokens > 0 ? cost * 1_000_000 / tokens : nil
            let complete = includesEstimates ? "Complete local total including API-rate estimates; not actual charges" : "Complete recorded local total"
            message = tokens > 0 ? complete : "Zero recorded tokens; rate undefined"
        } else {
            total = contributions.reduce(Decimal.zero) { $0 + ($1.value ?? 0) }
            message = includesEstimates && mode != .tokens ? "Complete local total including API-rate estimates; not actual charges" : "Complete recorded local total"
        }
    }

    public func formatted(_ value: Decimal) -> String { formatted(value, estimated: includesEstimates) }

    public func formatted(_ value: Decimal, estimated: Bool) -> String {
        switch mode {
        case .cost: "\(value) USD \(estimated ? "recorded + estimated" : "recorded")"
        case .tokens: "\(value) tokens"
        case .costPerMillion: "\(value) USD / million recorded tokens\(estimated ? " (includes estimates)" : "")"
        }
    }
}

import Foundation

public struct AIUsageRecordedHistoryModel: Codable, Sendable, Equatable {
    public let model: String
    public let events: Int
    public let missingTokens: Int
    public let missingCost: Int
    public let tokens: String?
    public let recordedCost: String?
    public let estimatedCost: String?
    public let costBasis: String?
    public let recordedEvents: Int?
    public let estimatedEvents: Int?
    private enum CodingKeys: String, CodingKey {
        case model, events, tokens
        case estimatedCost = "estimated_cost", costBasis = "cost_basis"
        case recordedEvents = "recorded_events", estimatedEvents = "estimated_events"
        case missingTokens = "missing_tokens", missingCost = "missing_cost", recordedCost = "recorded_cost"
    }
    public var detail: String {
        let recorded = recordedCost.map { $0 + " USD recorded" } ?? "recorded cost unknown"
        let costs = costBasis == nil ? recorded :
            "\(recorded); \(estimatedCost.map { $0 + " USD estimated" } ?? "estimated cost unknown"); "
            + "\(recordedEvents ?? 0) recorded / \(estimatedEvents ?? 0) estimated events; basis \(costBasis ?? "unknown")"
        return "\(model): \(costs); \(tokens.map { $0 + " tokens" } ?? "tokens unknown"); \(events) events; "
            + "\(missingTokens) missing tokens; \(missingCost) missing cost"
    }

    var hasCostCoverage: Bool {
        costBasis != nil || estimatedCost != nil || recordedEvents != nil || estimatedEvents != nil
    }

    func validateCost() throws {
        guard hasCostCoverage else {
            guard (recordedCost == nil) == (missingCost > 0) else {
                throw SymBrainUsageError.invalidValue("history recorded cost")
            }
            return
        }
        guard let recordedEvents, let estimatedEvents,
              (0...events).contains(recordedEvents), (0...events).contains(estimatedEvents),
              recordedEvents + estimatedEvents + missingCost == events,
              (recordedCost != nil) == (recordedEvents > 0),
              (estimatedCost != nil) == (estimatedEvents > 0) else {
            throw SymBrainUsageError.invalidValue("history cost coverage")
        }
        let expected = recordedEvents > 0 ? (estimatedEvents > 0 ? "mixed" : "recorded") :
            (estimatedEvents > 0 ? "estimated" : "unknown")
        guard costBasis == expected else { throw SymBrainUsageError.invalidValue("history cost basis") }
    }
}

/// Local, unattributed measurements and optional estimates. Never an account bill.
public struct AIUsageRecordedHistory: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case available, noData = "no_data", partial, unavailable }
    public struct Bucket: Codable, Sendable, Equatable {
        public let key: String
        public let models: [AIUsageRecordedHistoryModel]
    }
    public let scope: String
    public let attribution: String
    public let currency: String
    public let costBasis: String
    public let priceSnapshot: String?
    public let timezone: String
    public let status: Status
    public let excludedEvents: Int
    public let daily: [Bucket]
    public let periods: [Bucket]
    private enum CodingKeys: String, CodingKey {
        case scope, attribution, currency, timezone, status, daily, periods
        case priceSnapshot = "price_snapshot"
        case costBasis = "cost_basis", excludedEvents = "excluded_events"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        attribution = try c.decode(String.self, forKey: .attribution)
        currency = try c.decode(String.self, forKey: .currency)
        costBasis = try c.decode(String.self, forKey: .costBasis)
        priceSnapshot = try c.decodeIfPresent(String.self, forKey: .priceSnapshot)
        timezone = try c.decode(String.self, forKey: .timezone)
        status = try c.decode(Status.self, forKey: .status)
        excludedEvents = try c.decode(Int.self, forKey: .excludedEvents)
        daily = try c.decode([Bucket].self, forKey: .daily)
        periods = try c.decode([Bucket].self, forKey: .periods)
        guard scope == "local_machine", attribution == "unattributed", currency == "USD", ["recorded", "estimated", "mixed", "unknown"].contains(costBasis),
              !timezone.isEmpty, timezone.utf8.count <= 128,
              timezone.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }),
              (0...1_000_000).contains(excludedEvents), daily.count <= 30, periods.count <= 3,
              daily.map(\.key) == daily.map(\.key).sorted(),
              Set(daily.map(\.key)).count == daily.count,
              Set(periods.map(\.key)).count == periods.count,
              periods.allSatisfy({ ["today", "yesterday", "last_30_days"].contains($0.key) }),
              daily.allSatisfy({ Self.validDay($0.key) }),
              (daily + periods).reduce(0, { $0 + $1.models.count }) <= 40_000 else {
            throw SymBrainUsageError.invalidValue("recorded history")
        }
        if let priceSnapshot {
            guard !priceSnapshot.isEmpty, priceSnapshot.utf8.count <= 512,
                  priceSnapshot.range(of: #"\A[A-Za-z0-9._:/-]+\z"#, options: .regularExpression) != nil else {
                throw SymBrainUsageError.invalidValue("history price snapshot")
            }
        }
        if status == .noData || status == .unavailable {
            guard daily.isEmpty, periods.isEmpty else { throw SymBrainUsageError.invalidValue("history status") }
        }
        for bucket in daily + periods {
            guard !bucket.models.isEmpty, bucket.models.count <= 10_000,
                  Set(bucket.models.map(\.model)).count == bucket.models.count else {
                throw SymBrainUsageError.invalidValue("history models")
            }
            for row in bucket.models {
                guard !row.model.isEmpty, row.model.utf8.count <= 128,
                      row.model.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:/-]*\z"#, options: .regularExpression) != nil,
                      (1...10_000).contains(row.events), (0...row.events).contains(row.missingTokens),
                      (0...row.events).contains(row.missingCost),
                      (row.tokens == nil) == (row.missingTokens > 0) else {
                    throw SymBrainUsageError.invalidValue("history model")
                }
                try row.validateCost()
                if let cost = row.estimatedCost { _ = try Self.amount(cost, fraction: true) }
                if let tokens = row.tokens { _ = try Self.amount(tokens, fraction: false) }
                if let cost = row.recordedCost { _ = try Self.amount(cost, fraction: true) }
            }
        }
        let rows = (daily + periods).flatMap(\.models)
        if rows.contains(where: \.hasCostCoverage) {
            guard rows.allSatisfy(\.hasCostCoverage) else { throw SymBrainUsageError.invalidValue("history coverage") }
            let recorded = rows.contains { ($0.recordedEvents ?? 0) > 0 }
            let estimated = rows.contains { ($0.estimatedEvents ?? 0) > 0 }
            let expected = recorded ? (estimated ? "mixed" : "recorded") : (estimated ? "estimated" : "unknown")
            guard costBasis == expected else { throw SymBrainUsageError.invalidValue("history aggregate basis") }
        } else if !rows.isEmpty, costBasis != "recorded" {
            throw SymBrainUsageError.invalidValue("history legacy basis")
        }
        if status == .available, rows.contains(where: \.hasCostCoverage) {
            guard excludedEvents == 0, rows.allSatisfy({ $0.missingCost == 0 && $0.missingTokens == 0 }) else {
                throw SymBrainUsageError.invalidValue("history completeness")
            }
        }
    }

    /// No inferred dates: keys belong to the Brain host's calendar, including DST.
    private static func validDay(_ value: String) -> Bool {
        guard value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil else { return false }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        return format.date(from: value).map { format.string(from: $0) == value } ?? false
    }

    private static func amount(_ value: String, fraction: Bool) throws -> Decimal {
        let pattern = fraction ? #"\A[0-9]{1,10}(?:\.[0-9]{1,10})?\z"# : #"\A[0-9]{1,17}\z"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SymBrainUsageError.invalidValue("history decimal")
        }
        return amount
    }

    public func total(_ bucket: Bucket, cost: Bool) -> Decimal? {
        guard status == .available || (!cost && status == .partial),
              excludedEvents == 0, !bucket.models.isEmpty else { return nil }
        var sum: Decimal = 0
        for row in bucket.models {
            if cost {
                guard row.missingCost == 0 else { return nil }
                let values = [row.recordedCost, row.estimatedCost].compactMap { $0 }
                guard !values.isEmpty else { return nil }
                for raw in values {
                    guard let amount = try? Self.amount(raw, fraction: true) else { return nil }
                    sum += amount
                }
            } else {
                guard let raw = row.tokens, let amount = try? Self.amount(raw, fraction: false) else { return nil }
                sum += amount
            }
        }
        return sum
    }

    public var includesEstimates: Bool { costBasis == "estimated" || costBasis == "mixed" }
    public var costLabel: String { includesEstimates ? "recorded + estimated" : costBasis == "unknown" ? "unknown" : "recorded" }

    public func costDetail(_ bucket: Bucket) -> String {
        let recorded = bucket.models.compactMap(\.recordedCost).compactMap { try? Self.amount($0, fraction: true) }
        let estimated = bucket.models.compactMap(\.estimatedCost).compactMap { try? Self.amount($0, fraction: true) }
        let coverage = bucket.models.reduce(0) { $0 + ($1.recordedEvents ?? ($1.events - $1.missingCost)) }
        let estimates = bucket.models.reduce(0) { $0 + ($1.estimatedEvents ?? 0) }
        let missing = bucket.models.reduce(0) { $0 + $1.missingCost }
        return "Recorded subtotal: \(recorded.isEmpty ? "unknown" : "\(recorded.reduce(0, +)) USD"); "
            + "estimated subtotal: \(estimated.isEmpty ? "unknown" : "\(estimated.reduce(0, +)) USD"); "
            + "\(coverage) recorded / \(estimates) estimated / \(missing) missing cost events"
    }

    public func costLabel(for bucket: Bucket) -> String {
        let recorded = bucket.models.contains { $0.recordedCost != nil }
        let estimated = bucket.models.contains { $0.estimatedCost != nil }
        return estimated ? (recorded ? "recorded + estimated" : "estimated") : recorded ? "recorded" : "unknown"
    }

    public func summary(_ bucket: Bucket) -> String {
        let cost = total(bucket, cost: true).map { "\($0) USD \(costLabel(for: bucket))" } ?? (includesEstimates ? "Cost incomplete (recorded + estimated)" : "Recorded cost incomplete")
        let tokens = total(bucket, cost: false).map { "\($0) tokens" } ?? "tokens incomplete"
        return "\(cost) · \(tokens)"
    }
}

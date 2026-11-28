import Foundation

/// When the app may ask a provider again after failures (#452).
///
/// Consecutive failures back off on a doubling schedule (`interval * 2^(n-1)`, capped
/// at `cap`); a success clears them. A wait the provider asked for (HTTP 429
/// Retry-After) holds even for a manual refresh, which otherwise skips the backoff.
public struct AIUsageBackoff: Sendable {
    public static let cap: TimeInterval = 60 * 60

    private struct Entry: Sendable {
        var failures = 0
        var failureUntil = Date.distantPast
        var providerUntil = Date.distantPast
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func record(provider: String, error: String?, now: Date, interval: TimeInterval) {
        guard let error else {
            entries[provider] = nil
            return
        }
        var entry = entries[provider] ?? Entry()
        entry.failures += 1
        let delay = min(Self.cap, max(1, interval) * pow(2, Double(entry.failures - 1)))
        entry.failureUntil = now.addingTimeInterval(delay)
        if let wait = Self.providerWait(in: error) {
            entry.providerUntil = max(entry.providerUntil, now.addingTimeInterval(wait))
        }
        entries[provider] = entry
    }

    /// Whether `provider` must not be asked now. `manual` skips the failure backoff only.
    public func isWaiting(_ provider: String, now: Date, manual: Bool) -> Bool {
        guard let entry = entries[provider] else { return false }
        return now < entry.providerUntil || (!manual && now < entry.failureUntil)
    }

    /// The provider's requested wait in symbrain's rate-limit message
    /// (`... is rate limited; retry in 30s`).
    /// ponytail: parsed from the message text because the Brain report carries no
    /// structured retry field yet; switch to that field once `symbrain usage` emits one.
    public static func providerWait(in error: String) -> TimeInterval? {
        guard let range = error.range(of: #"retry in (\d+)s"#, options: .regularExpression) else { return nil }
        return TimeInterval(error[range].dropFirst("retry in ".count).dropLast())
    }
}

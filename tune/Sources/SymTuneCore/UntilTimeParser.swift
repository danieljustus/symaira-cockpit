import Foundation

/// Parse an `HH:MM` wall-clock time into the number of seconds until it occurs.
///
/// This lives in the core (alongside ``DurationParser``) so the roll-over-to-
/// tomorrow branch is covered by unit tests and visible to coverage reports —
/// the CLI target is not instrumented.
public enum UntilTimeParser: Sendable {
    /// Parse `HH:MM` into the number of seconds from `now` until that time.
    ///
    /// If the time has already passed today, the result rolls over to tomorrow
    /// (adds 24 hours). `now` is injectable so the roll-over branch can be
    /// tested deterministically.
    public static func parse(_ raw: String, now: Date = Date()) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              hour >= 0, hour <= 23,
              minute >= 0, minute <= 59
        else {
            throw TuneError.usage("awake --until: expected HH:MM (24-hour), got '\(trimmed)'.")
        }

        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var target = cal.date(from: components) else {
            throw TuneError.usage("awake --until: could not compute target date from \(hour):\(minute).")
        }

        // If the time has already passed today, schedule for tomorrow.
        if target <= now {
            target = target.addingTimeInterval(86_400)
        }

        return target.timeIntervalSince(now)
    }
}

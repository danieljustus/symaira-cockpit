import Foundation

public enum DurationParser: Sendable {
    /// Parse a string into a TimeInterval (seconds).
    /// Supports formats like "500ms", "2s", "1.5s", "5m", "1h", or raw seconds "2".
    public static func parse(_ string: String) throws -> TimeInterval {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TuneError.usage("Duration string cannot be empty")
        }

        if trimmed.hasSuffix("ms") {
            let numStr = trimmed.dropLast(2)
            guard let value = Double(numStr) else {
                throw TuneError.usage("Invalid numeric value for duration: '\(trimmed)'")
            }
            return value / 1000.0
        }

        if trimmed.hasSuffix("s") {
            let numStr = trimmed.dropLast(1)
            guard let value = Double(numStr) else {
                throw TuneError.usage("Invalid numeric value for duration: '\(trimmed)'")
            }
            return value
        }

        if trimmed.hasSuffix("m") {
            let numStr = trimmed.dropLast(1)
            guard let value = Double(numStr) else {
                throw TuneError.usage("Invalid numeric value for duration: '\(trimmed)'")
            }
            return value * 60.0
        }

        if trimmed.hasSuffix("h") {
            let numStr = trimmed.dropLast(1)
            guard let value = Double(numStr) else {
                throw TuneError.usage("Invalid numeric value for duration: '\(trimmed)'")
            }
            return value * 3600.0
        }

        guard let value = Double(trimmed) else {
            throw TuneError.usage("Invalid numeric value for duration: '\(trimmed)'")
        }
        return value
    }
}

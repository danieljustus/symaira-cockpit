import Foundation

/// Apple's own battery-health figures, as published by
/// `system_profiler SPPowerDataType` under "Health Information".
/// Both fields are nil when the block is missing or unparseable — callers
/// report that as absent JSON keys, never as zeros or guesses.
public struct AppleBatteryHealth: Sendable, Equatable {
    /// Whole-percent "Maximum Capacity" (the figure System Settings shows).
    public let maximumCapacityPercent: Int?
    /// "Condition" verdict (e.g. "Normal", "Replace Soon", "Service Battery").
    public let condition: String?

    public init(maximumCapacityPercent: Int? = nil, condition: String? = nil) {
        self.maximumCapacityPercent = maximumCapacityPercent
        self.condition = condition
    }
}

/// Pure string parser for `system_profiler SPPowerDataType` output.
///
/// No hardware and no subprocess are involved: feed it the captured text and
/// get the `Condition:` / `Maximum Capacity:` values out. Unparseable or
/// localized output yields nil fields rather than guesses, so `symtune`
/// degrades to "Apple figures unavailable" instead of inventing numbers.
public enum BatteryHealthParser {
    public static func parse(_ output: String) -> AppleBatteryHealth {
        var maximumCapacityPercent: Int?
        var condition: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Condition:"), condition == nil {
                let value = String(line.dropFirst("Condition:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { condition = value }
            } else if line.hasPrefix("Maximum Capacity:"), maximumCapacityPercent == nil {
                let value = String(line.dropFirst("Maximum Capacity:".count))
                    .trimmingCharacters(in: .whitespaces)
                // Some localizations emit "97 %" with a space before the sign.
                let cleaned = value
                    .replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespaces)
                maximumCapacityPercent = Int(cleaned)
            }
        }

        return AppleBatteryHealth(
            maximumCapacityPercent: maximumCapacityPercent,
            condition: condition
        )
    }
}

/// Abstraction over Apple's health figures so `BatteryService` can be
/// unit-tested without spawning `system_profiler`.
public protocol AppleBatteryHealthProviding: Sendable {
    func readAppleHealth() -> AppleBatteryHealth
}

/// Production provider: runs `system_profiler SPPowerDataType`, parses the
/// "Health Information" block, and caches the result.
///
/// `system_profiler` takes ~1-2 s, so the result is cached with a TTL —
/// this keeps the subprocess off hot loops and out of the menu-bar refresh
/// cycle. `shared` is process-wide so the CLI, the MCP server and the app
/// reuse a single cache.
public final class SystemProfilerBatteryHealthProvider: AppleBatteryHealthProviding, @unchecked Sendable {
    public static let shared = SystemProfilerBatteryHealthProvider()

    private let lock = NSLock()
    private var cached: AppleBatteryHealth?
    private var cachedAt: TimeInterval?
    private let cacheTTL: TimeInterval
    private let runner: @Sendable () -> AppleBatteryHealth

    public init(cacheTTL: TimeInterval = 300) {
        self.cacheTTL = cacheTTL
        self.runner = { Self.runSystemProfiler() }
    }

    /// Test seam: inject a runner so no subprocess is spawned.
    init(cacheTTL: TimeInterval = 300, runner: @escaping @Sendable () -> AppleBatteryHealth) {
        self.cacheTTL = cacheTTL
        self.runner = runner
    }

    public func readAppleHealth() -> AppleBatteryHealth {
        lock.lock()
        defer { lock.unlock() }
        let now = Date.timeIntervalSinceReferenceDate
        if let cached, let cachedAt, now - cachedAt < cacheTTL {
            return cached
        }
        let health = runner()
        cached = health
        cachedAt = now
        return health
    }

    private static func runSystemProfiler() -> AppleBatteryHealth {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType"]
        // Prefer English labels so the parser sees "Condition:" /
        // "Maximum Capacity:" regardless of the user's locale.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return AppleBatteryHealth()
        }

        // Bound the wait so a wedged process degrades to absent fields
        // instead of hanging the caller.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        _ = finished.wait(timeout: .now() + 10)
        if process.isRunning { process.terminate() }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return BatteryHealthParser.parse(text)
    }
}

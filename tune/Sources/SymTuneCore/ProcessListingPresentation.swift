import Foundation

/// Argument parsing and table rendering for the `processes` command.
///
/// This lives in the core rather than in the CLI target because the CLI
/// executable is **not instrumented for coverage**: `SymTuneCLITests` exercises
/// it by spawning the built binary, so no profile is collected for that process
/// and any logic left in `Sources/symtune/` is invisible to coverage reports —
/// absent from the numbers rather than counted as uncovered. Keeping the
/// decisions here (what the flags mean, how the table is laid out) means they
/// are measured and unit-tested; the CLI keeps only the I/O.
public enum ProcessListingPresentation: Sendable {

    // MARK: - Options

    /// The resolved form of `processes [--sort cpu|memory] [--limit N] [--interval <seconds>] [--json]`.
    public struct Options: Equatable, Sendable {
        public var sortedBy: ProcessSortKey
        public var limit: Int
        /// Seconds between the two sweeps that establish the CPU baseline.
        public var interval: TimeInterval
        public var wantsJSON: Bool
        /// `--help`/`-h` was requested; the caller prints usage and stops.
        public var wantsHelp: Bool

        public init(
            sortedBy: ProcessSortKey = .cpu,
            limit: Int = ProcessUsageService.defaultLimit,
            interval: TimeInterval = 1.0,
            wantsJSON: Bool = false,
            wantsHelp: Bool = false
        ) {
            self.sortedBy = sortedBy
            self.limit = limit
            self.interval = interval
            self.wantsJSON = wantsJSON
            self.wantsHelp = wantsHelp
        }
    }

    /// Usage text for `--help`, one line per entry.
    public static let usageLines = [
        "Usage: symtune processes [--sort cpu|memory] [--limit N] [--interval <seconds>] [--json]",
        "",
        "Rank running processes by CPU or memory usage. CPU is a rate, so the",
        "command samples twice --interval seconds apart (default 1.0) before",
        "reporting. Processes owned by another user are counted but not readable",
        "without elevation.",
    ]

    /// Parse the command's arguments.
    ///
    /// - Throws: ``TuneError/usage(_:)`` naming the offending flag. An unknown
    ///   flag is an error rather than a silent default, so a typo in a script
    ///   does not quietly produce a CPU ranking when memory was meant.
    public static func parseOptions(_ args: [String]) throws -> Options {
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return Options(wantsHelp: true)
        }

        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json":
                options.wantsJSON = true
            case "--sort":
                index += 1
                guard index < args.count,
                      let parsed = ProcessSortKey(rawValue: args[index].lowercased()) else {
                    throw TuneError.usage("processes: --sort expects 'cpu' or 'memory'")
                }
                options.sortedBy = parsed
            case "--limit":
                index += 1
                guard index < args.count, let parsed = Int(args[index]), parsed > 0 else {
                    throw TuneError.usage("processes: --limit expects a positive integer")
                }
                options.limit = parsed
            case "--interval":
                index += 1
                guard index < args.count, let parsed = TimeInterval(args[index]), parsed > 0 else {
                    throw TuneError.usage("processes: --interval expects a positive number of seconds")
                }
                options.interval = parsed
            default:
                throw TuneError.usage("processes: unexpected argument '\(arg)'")
            }
            index += 1
        }
        return options
    }

    // MARK: - Table

    /// Column widths for the plain-text table.
    static let pidWidth = 8
    static let nameWidth = 34
    static let cpuWidth = 8
    static let memoryWidth = 10
    /// Total width of the rule under the header.
    static let ruleWidth = pidWidth + nameWidth + cpuWidth + 1 + memoryWidth

    /// Render `report` as the plain-text table, one string per line.
    ///
    /// Padding is manual because `String(format:)` ignores width flags on `%@`
    /// on Apple platforms — `%-8@` silently produces an unpadded column.
    public static func tableLines(for report: ProcessUsageReport) -> [String] {
        var lines = [
            column("PID", pidWidth)
                + column("PROCESS", nameWidth)
                + column("CPU %", cpuWidth, alignRight: true)
                + " "
                + column("MEMORY", memoryWidth, alignRight: true),
            String(repeating: "-", count: ruleWidth),
        ]
        for process in report.processes {
            lines.append(
                column(String(process.pid), pidWidth)
                    + column(process.name, nameWidth)
                    + column(cpuText(for: process), cpuWidth, alignRight: true)
                    + " "
                    + column(MetricFormatting.bytes(process.memoryBytes), memoryWidth, alignRight: true)
            )
        }
        return lines
    }

    /// CPU column for one row: `n/a` until a second sweep exists, so an
    /// unavailable rate never reads as genuine idleness.
    static func cpuText(for process: ProcessUsage) -> String {
        guard let percent = process.cpuPercent else { return "n/a" }
        return String(format: "%.1f", percent)
    }

    /// Pad or clip `text` to `width`.
    static func column(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
        let clipped = String(text.prefix(width))
        let padding = String(repeating: " ", count: max(0, width - clipped.count))
        return alignRight ? padding + clipped : clipped + padding
    }
}

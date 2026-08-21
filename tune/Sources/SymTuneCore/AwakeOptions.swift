import Foundation

/// Argument parsing and option resolution for the `awake` command.
///
/// This lives in the core rather than in the CLI target because the CLI
/// executable is **not instrumented for coverage**: `SymTuneCLITests` exercises
/// it by spawning the built binary, so no profile is collected for that process
/// and any logic left in `Sources/symtune/` is invisible to coverage reports.
/// Keeping the decisions here (the flag loop, `--for`/`--until`/`--seconds`
/// precedence, HH:MM roll-over) means they are measured and unit-tested; the
/// CLI target keeps only the I/O.
public enum AwakeOptions: Sendable {

    /// The `awake status` / `awake off` subcommands.
    public enum Subcommand: String, Equatable, Sendable {
        case status
        case off
    }

    /// The resolved form of `awake [--display] [--seconds N] [--for <duration>] [--until HH:MM]`
    /// plus its `status`/`off` subcommands.
    public struct Options: Equatable, Sendable {
        /// A `status`/`off` subcommand when the first argument was one.
        /// When non-nil the remaining flags are ignored, matching the CLI's
        /// established behaviour of handling the subcommand and returning.
        public var subcommand: Subcommand?
        /// Resolved wake duration in seconds (`nil` = block until Ctrl-C).
        public var seconds: Double?
        /// `--display` also keeps the screen on.
        public var preventDisplaySleep: Bool

        public init(
            subcommand: Subcommand? = nil,
            seconds: Double? = nil,
            preventDisplaySleep: Bool = false
        ) {
            self.subcommand = subcommand
            self.seconds = seconds
            self.preventDisplaySleep = preventDisplaySleep
        }
    }

    /// Parse `awake`'s arguments into ``Options``.
    ///
    /// The `status`/`off` subcommands must be the first argument. Duration
    /// flags are resolved with `--until` taking precedence over `--for`, which
    /// takes precedence over `--seconds`. An unknown flag is an error rather
    /// than a silent default, so a typo in a script is visible.
    public static func parseOptions(_ args: [String]) throws -> Options {
        if let first = args.first, first == "status" || first == "off" {
            return Options(subcommand: Subcommand(rawValue: first))
        }

        var seconds: Double?
        var preventDisplaySleep = false
        var forDuration: String?
        var untilTime: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--display":
                preventDisplaySleep = true
            case "--seconds", "-s":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    throw TuneError.usage("awake --seconds requires a number.")
                }
                seconds = value
            case "--for":
                index += 1
                guard index < args.count else {
                    throw TuneError.usage("awake --for requires a duration, e.g. 30m, 2h.")
                }
                forDuration = args[index]
            case "--until":
                index += 1
                guard index < args.count else {
                    throw TuneError.usage("awake --until requires a time in HH:MM format.")
                }
                untilTime = args[index]
            default:
                throw TuneError.usage("awake: unknown option '\(args[index])'.")
            }
            index += 1
        }

        // Resolve the duration from --for or --until, in that precedence order.
        if let forDuration {
            seconds = try DurationParser.parse(forDuration)
        }
        if let untilTime {
            seconds = try UntilTimeParser.parse(untilTime)
        }

        return Options(seconds: seconds, preventDisplaySleep: preventDisplaySleep)
    }
}

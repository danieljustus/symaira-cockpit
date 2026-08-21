import Foundation

/// Argument parsing for the `status` command.
///
/// This lives in the core rather than in the CLI target because the CLI
/// executable is **not instrumented for coverage** — the CLI keeps only the
/// I/O, while the option decisions here are measured and unit-tested.
public enum StatusOptions: Sendable {

    /// The resolved form of `status [--json] [--watch [--interval <duration>]]`.
    public struct Options: Equatable, Sendable {
        public var isWatch: Bool
        public var interval: TimeInterval
        public var isJson: Bool

        public init(isWatch: Bool = false, interval: TimeInterval = 1.0, isJson: Bool = false) {
            self.isWatch = isWatch
            self.interval = interval
            self.isJson = isJson
        }
    }

    /// Parse `status`'s arguments into ``Options``.
    ///
    /// An unknown flag is an error rather than a silent default, so a typo in
    /// a script is visible.
    public static func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--watch":
                options.isWatch = true
            case "--interval":
                index += 1
                guard index < args.count else {
                    throw TuneError.usage("status: --interval requires a value.")
                }
                options.interval = try DurationParser.parse(args[index])
            case "--json":
                options.isJson = true
            default:
                throw TuneError.usage("status: unknown option '\(args[index])'")
            }
            index += 1
        }
        return options
    }
}

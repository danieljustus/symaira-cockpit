import Foundation

/// Argument parsing for the `history` command.
///
/// This lives in the core rather than in the CLI target because the CLI
/// executable is **not instrumented for coverage** — the CLI keeps only the
/// I/O, while the option decisions here are measured and unit-tested.
public enum HistoryOptions: Sendable {

    /// The resolved form of `history [--json] [--limit N | -n N]`.
    public struct Options: Equatable, Sendable {
        public var isJson: Bool
        public var limit: Int?

        public init(isJson: Bool = false, limit: Int? = 100) {
            self.isJson = isJson
            self.limit = limit
        }
    }

    /// Parse `history`'s arguments into ``Options``.
    ///
    /// An unknown flag is an error rather than a silent default, so a typo in
    /// a script is visible.
    public static func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                options.isJson = true
            case "--limit", "-n":
                index += 1
                guard index < args.count, let val = Int(args[index]) else {
                    throw TuneError.usage("history: --limit requires an integer value")
                }
                options.limit = val
            default:
                throw TuneError.usage("history: unknown option '\(args[index])'")
            }
            index += 1
        }
        return options
    }
}

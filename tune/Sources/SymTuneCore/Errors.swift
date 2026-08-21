import Foundation

/// Domain error type for symtune. Carries a human-readable message and maps to
/// a typed `ExitCode` so the CLI exit status is meaningful for scripts/agents.
public enum TuneError: Error, Sendable, CustomStringConvertible {
    /// Bad command or flag usage.
    case usage(String)
    /// Invalid configuration file/value.
    case config(String)
    /// Missing macOS permission or privileged helper.
    case permission(String)
    /// Capability not available on this hardware or licensing tier.
    case unsupported(String)
    /// Capability is planned but not wired in this version.
    case notImplemented(String)
    /// Generic runtime failure (syscall, IOKit, etc.).
    case failed(String)

    public var description: String {
        switch self {
        case .usage(let message): return message
        case .config(let message): return "config error: \(message)"
        case .permission(let message): return "permission error: \(message)"
        case .unsupported(let message): return "unsupported: \(message)"
        case .notImplemented(let message): return "not implemented: \(message)"
        case .failed(let message): return message
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage, .config: return ExitCode.usage.rawValue
        case .permission: return ExitCode.permission.rawValue
        case .unsupported, .notImplemented: return ExitCode.unsupported.rawValue
        case .failed: return ExitCode.error.rawValue
        }
    }
}

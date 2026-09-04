import Foundation

/// Domain error type for symtune. Carries a human-readable message and maps to
/// a typed `ExitCode` so the CLI exit status is meaningful for scripts/agents.
///
/// `LocalizedError` conformance matters beyond convention: SwiftUI code across
/// SymTuneUI (`ControlCards`, `PreferencesView`, `ProcessesViewModel`, …)
/// surfaces failures via `error.localizedDescription`, which — without this
/// conformance — ignores `description` entirely and falls back to Swift's
/// generic NSError bridging (e.g. "SymTuneCore.TuneError error 2"), hiding
/// every carefully-written message behind a useless case-index string.
public enum TuneError: Error, Sendable, CustomStringConvertible, LocalizedError {
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

    public var errorDescription: String? { description }

    public var exitCode: Int32 {
        switch self {
        case .usage, .config: return ExitCode.usage.rawValue
        case .permission: return ExitCode.permission.rawValue
        case .unsupported, .notImplemented: return ExitCode.unsupported.rawValue
        case .failed: return ExitCode.error.rawValue
        }
    }
}

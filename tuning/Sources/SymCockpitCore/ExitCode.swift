import Foundation

/// Typed process exit codes, aligned with the Symaira ecosystem convention
/// (see ../ECOSYSTEM.md §6). `serve` (MCP) never calls these — it reports
/// errors as JSON-RPC error frames instead.
public enum ExitCode: Int32, Sendable {
    /// Successful execution.
    case ok = 0
    /// Generic runtime error.
    case error = 1
    /// Bad CLI flags or configuration file.
    case usage = 2
    /// Missing macOS permission / privileged helper.
    case permission = 3
    /// Capability not available on this hardware/tier, or not yet implemented.
    case unsupported = 4
}

import Foundation

/// Protocol defining the IPC surface for a privileged SMC helper.
/// The helper daemon (installed via `SMAppService`) implements this protocol;
/// the core talks to it over XPC. The helper enforces clamp ranges and
/// never disables firmware thermal protection.
///
/// In the current direct-write model this protocol is not used by the CLI.
/// It remains as the contract for a future optional helper daemon that runs
/// with elevated privileges so users do not have to run the whole `symtune`
/// binary as root.
///
/// The helper is installed/managed via `SMAppService`:
/// - Bundle identifier: `com.symaira.symtune-helper`
/// - Install: `SMAppService.daemon(plistName: "com.symaira.symtune-helper")`
/// - The helper validates all requests against `SafetyPolicy` ranges before
///   applying them to the SMC.
///
/// ## Client authentication (mandatory)
///
/// Clamping bounds *what* can be done, not *by whom*. An `SMAppService` daemon
/// that exports an `NSXPCListener` without peer validation accepts a connection
/// from any local process, which turns the root helper into a local
/// privilege-escalation primitive: any unprivileged app on the machine could
/// pin the fans or inhibit charging. The helper MUST therefore authenticate
/// every client and refuse the connection otherwise:
///
/// - **Code-signing requirement, both directions.** Pin
///   `NSXPCConnection.setCodeSigningRequirement` to the `symtune` Developer ID
///   team and bundle identifier on both sides of the connection (helper and
///   client), so the helper only accepts clients signed by the `symtune` team
///   and the client only accepts the expected helper.
/// - **Audit-token validation.** Validate the peer with
///   `SecCodeCopyGuestWithAttributes` against the connection's audit token
///   (`NSXPCConnection.auditToken`), never a PID claimed by the peer. A PID can
///   be reused by an unrelated process once the original exits (the PID-reuse
///   race); the audit token is bound to the process the connection was accepted
///   from and cannot be spoofed by the peer.
/// - **Hardened-runtime escape entitlements, rejected.** Reject peers whose
///   code signature carries any of the following entitlements, which defeat
///   the hardened runtime:
///   - `com.apple.security.cs.allow-dyld-environment-variables`
///   - `com.apple.security.cs.disable-library-validation`
///   - `com.apple.security.cs.allow-unsigned-executable-memory`
///   - `com.apple.security.cs.allow-jit`
/// - **`SecCodeStatus` requirements.** The peer's `SecCode` status must satisfy
///   `valid`, `hard`, `kill`, `libraryValidation`, and `runtime`.
public protocol SMCHelperProtocol: Sendable {
    /// Write a fan speed fraction (0.0–1.0) to the SMC.
    /// The helper clamps to `SafetyPolicy.fanFractionMin/Max` and ensures
    /// the firmware auto curve floor is never violated.
    func setFanFraction(_ fraction: Double) throws

    /// Set a battery charge limit percent (50–100).
    /// The helper clamps to `SafetyPolicy.chargeLimitMin/Max` and handles
    /// Intel vs Apple Silicon SMC key differences.
    func setChargeLimit(_ percent: Int) throws

    /// Clear the battery charge limit (revert to firmware default).
    func clearChargeLimit() throws

    /// Restore all SMC overrides to firmware defaults (on helper shutdown).
    func restoreDefaults() throws
}

/// Error type for helper IPC failures.
public enum SMCHelperError: Error, Sendable, CustomStringConvertible {
    case helperNotInstalled
    case connectionFailed(String)
    case requestRejected(String)
    case clampedToSafeRange(String)

    public var description: String {
        switch self {
        case .helperNotInstalled:
            return "privileged SMC helper not installed — run `symtune permissions` for setup instructions"
        case .connectionFailed(let detail):
            return "helper connection failed: \(detail)"
        case .requestRejected(let detail):
            return "helper rejected request: \(detail)"
        case .clampedToSafeRange(let detail):
            return "value clamped to safe range: \(detail)"
        }
    }
}

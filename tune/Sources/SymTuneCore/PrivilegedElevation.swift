import Darwin
import Foundation
import SymCockpitHistory

/// On-demand privilege escalation for operations that need root (SMC fan
/// writes, per-process GPU sampling via `powermetrics`) but are invoked from
/// the cockpit GUI, which never runs as root.
///
/// Uses `osascript`'s `do shell script … with administrator privileges` — the
/// same standard, Apple-documented mechanism many notarized menu-bar apps
/// (and Homebrew's own installer) use for occasional privileged actions
/// without installing a persistent daemon. Nothing is cached, stored, or
/// re-used across calls: every invocation pops the system's own password
/// dialog. ``SMCHelperProtocol`` remains the contract for a future signed XPC
/// daemon that would avoid the repeated prompt; this is the pragmatic path
/// available today, and it is deliberately opt-in per call site — CLI and MCP
/// callers never trigger it implicitly, since a blocking GUI password prompt
/// would hang a headless/agent invocation with no human present to answer it.
public enum PrivilegedElevation: Sendable {
    public enum ElevationError: Error, Sendable, CustomStringConvertible, Equatable {
        case executableUnavailable
        case cancelledByUser
        case failed(String)

        public var description: String {
            switch self {
            case .executableUnavailable:
                return "the symcockpit CLI is not installed; install it with "
                    + "`brew install danieljustus/tap/symcockpit` to enable this from the app"
            case .cancelledByUser:
                return "cancelled — administrator password was not provided"
            case .failed(let message):
                return message
            }
        }
    }

    /// Runs `symcockpit <arguments>` as root via a one-time administrator
    /// authorization prompt and returns its captured standard output.
    ///
    /// Each argument is embedded through AppleScript's own `quoted form of`,
    /// so no manual shell-escaping of caller-supplied text happens here — the
    /// only string this function assembles by hand is the resolved binary
    /// path plus fixed argument separators, and that is escaped for the
    /// AppleScript string-literal syntax it is embedded in.
    @discardableResult
    public static func runSymCockpit(
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 120
    ) throws -> Data {
        guard let binaryPath = BoundedProcessRunner.resolveExecutablePath("symcockpit") else {
            throw ElevationError.executableUnavailable
        }

        let quotedParts = ([binaryPath] + arguments).map {
            "(quoted form of \(appleScriptStringLiteral($0)))"
        }
        let script = "do shell script \(quotedParts.joined(separator: " & \" \" & ")) with administrator privileges"

        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            throw ElevationError.failed("could not launch the authorization prompt: \(error.localizedDescription)")
        }

        guard !result.timedOut else {
            throw ElevationError.failed("the privileged command did not finish in time")
        }
        guard result.terminationStatus == 0 else {
            let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""
            if stderrText.contains("User canceled") || stderrText.contains("(-128)") {
                throw ElevationError.cancelledByUser
            }
            throw ElevationError.failed(stderrText.isEmpty ? "privileged command failed" : stderrText)
        }
        return result.standardOutput
    }

    /// Whether *this exact process* currently has root — the only thing that
    /// makes a direct SMC write (or an unprivileged `powermetrics` call)
    /// succeed. A read-only SMC connection opens unprivileged and says
    /// nothing about write access; conflating the two previously made
    /// `doctor`/`permissions` claim fan control was available for GUI
    /// processes that could never actually write.
    public static var isRunningAsRoot: Bool { geteuid() == 0 }

    /// Whether a ``FanControlError`` looks like a privilege problem worth
    /// retrying through elevation, as opposed to a hardware/platform mismatch
    /// that a password prompt cannot fix.
    static func isPermissionShaped(_ error: FanControlError) -> Bool {
        switch error {
        case .fanModeWriteRejected, .targetRPMWriteFailed:
            return true
        case .noFansDetected, .unsupportedPlatform:
            return false
        }
    }

    /// Formats a value for a shell argument in a fixed, locale-independent
    /// way — `String(format:)` without an explicit locale uses the user's
    /// current locale, which would emit `0,5000` instead of `0.5000` on a
    /// German system and silently break the CLI's `Double(arg)` parsing.
    static func shellFormat(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Escapes `value` for embedding as an AppleScript double-quoted string
    /// literal. `value` here is always either our own resolved binary path or
    /// a value we formatted ourselves (never unsanitized external input) —
    /// this still escapes defensively since paths can contain arbitrary
    /// characters (e.g. spaces, as in "Symaira Dev").
    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

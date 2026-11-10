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
/// dialog. The signed app can instead opt in to an `SMAppService` fan helper
/// (``FanHelperRouting``) that avoids the repeated prompt; this stays the
/// path for unsigned and local builds and whenever the helper is off, and it
/// is deliberately opt-in per call site — CLI and MCP
/// callers never trigger it implicitly, since a blocking GUI password prompt
/// would hang a headless/agent invocation with no human present to answer it.
public enum PrivilegedElevation: Sendable {
    public enum ElevationError: Error, Sendable, CustomStringConvertible, Equatable {
        case executableUnavailable
        case untrustedExecutable(String)
        /// The root-owned copy is trustworthy but reports a different version
        /// than the host that is about to elevate it (issue #409).
        case staleExecutable(path: String, found: String, expected: String)
        /// The root-owned copy's version could not be established, so it is
        /// not elevated either: an unknown binary is not a matching one.
        case unverifiableExecutable(path: String, reason: String)
        case cancelledByUser
        case failed(String)

        public var description: String {
            switch self {
            case .executableUnavailable:
                return "the symcockpit CLI is not installed in a root-owned location; install it with "
                    + "`brew install danieljustus/tap/symcockpit`, then place a root-owned copy with "
                    + "`sudo install -o root -g wheel -m 755 \"$(brew --prefix)/bin/symcockpit\" /usr/local/bin/symcockpit`"
            case .untrustedExecutable(let reason):
                return reason
            case .staleExecutable(let path, let found, let expected):
                return "refusing to run \(path) as an administrator: it is symcockpit \(found), but this build is "
                    + "\(expected), so fan control would run different code. Enable the optional fan helper in "
                    + "Preferences, or refresh the root-owned copy with `\(PrivilegedElevation.refreshCommand(for: path))`"
            case .unverifiableExecutable(let path, let reason):
                return "refusing to run \(path) as an administrator: its version could not be verified "
                    + "(\(reason)). Enable the optional fan helper in Preferences, or refresh the root-owned copy "
                    + "with `\(PrivilegedElevation.refreshCommand(for: path))`"
            case .cancelledByUser:
                return "cancelled — administrator password was not provided"
            case .failed(let message):
                return message
            }
        }
    }

    // MARK: - Expected version (issue #409)

    /// The `symcockpit` release this host ships, injected by the hosts that
    /// know it (the root `symcockpit` dispatcher and `SymCockpitApp`). This
    /// package only knows the Tune component version, which is not the shipped
    /// CLI version, so it cannot guess. While nothing was injected — the
    /// package-local `symtune` and `SymCockpitMenuBarApp` — the version check
    /// is skipped rather than compared against a made-up value.
    private final class ExpectedVersionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: String?) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    private static let expectedVersionStore = ExpectedVersionStore()

    /// Registers the `symcockpit` version a root-owned copy must report before
    /// it is elevated. Pass `nil` to clear it.
    public static func setExpectedVersion(_ version: String?) {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        expectedVersionStore.set(trimmed?.isEmpty == false ? trimmed : nil)
    }

    /// The injected expected version, if any.
    public static var expectedVersion: String? { expectedVersionStore.get() }

    /// How long the unprivileged `version --json` probe may run.
    static let versionProbeTimeoutSeconds: TimeInterval = 5

    /// The shell command that refreshes the root-owned copy at `path`.
    /// `install` follows the Homebrew symlink, so the source needs no
    /// `readlink`; `-m 755 -o root -g wheel` keeps the ownership the
    /// elevation checks demand.
    static func refreshCommand(for path: String) -> String {
        "sudo install -m 755 -o root -g wheel \"$(brew --prefix)/bin/symcockpit\" \(path)"
    }

    /// What an unprivileged `<path> version --json` probe established.
    enum VersionProbeOutcome: Sendable, Equatable {
        case version(String)
        case unreadable(String)
    }

    /// Runs one bounded, unprivileged subprocess and returns its result. A
    /// seam so tests never execute a real binary.
    typealias VersionProbeRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval,
        _ environment: [String: String]
    ) throws -> BoundedProcessResult

    static let defaultVersionProbeRunner: VersionProbeRunner = { executable, arguments, timeout, environment in
        try BoundedProcessRunner.run(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeout,
            environment: environment
        )
    }

    /// Asks the already-trusted binary at `path` for its version without
    /// elevation and without touching the network.
    ///
    /// The update check is disabled both ways it can be: `--no-update-check`
    /// and `SYMCOCKPIT_CHECK_UPDATES=0`. Older releases ignore an unknown
    /// flag, and the environment is scrubbed down to what the probe needs so
    /// nothing in the caller's environment steers the child.
    static func probeVersion(
        of path: String,
        runner: VersionProbeRunner = defaultVersionProbeRunner
    ) -> VersionProbeOutcome {
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "SYMCOCKPIT_CHECK_UPDATES": "0",
        ]
        let result: BoundedProcessResult
        do {
            result = try runner(
                path,
                ["version", "--json", "--no-update-check"],
                versionProbeTimeoutSeconds,
                environment
            )
        } catch {
            return .unreadable("could not run `version --json`: \(error.localizedDescription)")
        }
        if result.timedOut {
            return .unreadable("`version --json` did not answer within \(Int(versionProbeTimeoutSeconds)) s")
        }
        guard result.terminationStatus == 0 else {
            return .unreadable("`version --json` exited with status \(result.terminationStatus)")
        }
        if result.truncated {
            return .unreadable("`version --json` produced more output than expected")
        }
        guard let object = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let version = (object["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else {
            return .unreadable("`version --json` did not print a version")
        }
        return .version(version)
    }

    /// Refuses `path` unless it reports exactly `expected`. A no-op while no
    /// expected version was injected. The caller must already have validated
    /// `path` as root-owned: this never relaxes that check.
    static func requireMatchingVersion(
        path: String,
        expected: String?,
        runner: VersionProbeRunner = defaultVersionProbeRunner
    ) throws {
        guard let expected else { return }
        switch probeVersion(of: path, runner: runner) {
        case .version(let found):
            guard found == expected else {
                throw ElevationError.staleExecutable(path: path, found: found, expected: expected)
            }
        case .unreadable(let reason):
            throw ElevationError.unverifiableExecutable(path: path, reason: reason)
        }
    }

    /// The trusted binary, additionally proven to be the release this host
    /// ships. Every elevation goes through here.
    static func resolveVerifiedSymCockpit(
        resolve: () throws -> String = {
            try BoundedProcessRunner.resolvePrivilegedExecutablePath("symcockpit")
        },
        expectedVersion: String? = PrivilegedElevation.expectedVersion,
        runner: VersionProbeRunner = defaultVersionProbeRunner
    ) throws -> String {
        let path = try resolveTrustedSymCockpit(resolve: resolve)
        try requireMatchingVersion(path: path, expected: expectedVersion, runner: runner)
        return path
    }

    /// The state of the privileged fan path, for `doctor`. Never elevates.
    public struct PrivilegedExecutableStatus: Sendable, Equatable {
        public enum State: String, Sendable, Equatable {
            /// Root-owned, and its version equals the expected one.
            case matching
            /// Root-owned, but a different version.
            case stale
            /// Root-owned and readable, but this host knows no expected version.
            case unchecked
            /// Root-owned, but its version could not be established.
            case unverifiable
            /// A copy exists but fails the root-ownership checks.
            case untrusted
            /// No copy found.
            case notInstalled
        }

        public let state: State
        public let path: String?
        public let foundVersion: String?
        public let expectedVersion: String?
        public let detail: String

        /// True only when elevation would actually go ahead.
        public var usable: Bool { state == .matching || state == .unchecked }
    }

    /// Inspects the privileged fan path the same way an elevation would,
    /// without running anything as root.
    static func inspectPrivilegedExecutable(
        resolve: () throws -> String = {
            try BoundedProcessRunner.resolvePrivilegedExecutablePath("symcockpit")
        },
        expectedVersion: String? = PrivilegedElevation.expectedVersion,
        runner: VersionProbeRunner = defaultVersionProbeRunner
    ) -> PrivilegedExecutableStatus {
        let path: String
        do {
            path = try resolveTrustedSymCockpit(resolve: resolve)
        } catch ElevationError.executableUnavailable {
            return PrivilegedExecutableStatus(
                state: .notInstalled, path: nil, foundVersion: nil, expectedVersion: expectedVersion,
                detail: "No root-owned symcockpit found; the administrator-prompt fan path is unavailable. "
                    + "Install one with `\(refreshCommand(for: "/usr/local/bin/symcockpit"))`, or enable the "
                    + "optional fan helper."
            )
        } catch {
            return PrivilegedExecutableStatus(
                state: .untrusted, path: nil, foundVersion: nil, expectedVersion: expectedVersion,
                detail: "\(error)"
            )
        }
        switch probeVersion(of: path, runner: runner) {
        case .unreadable(let reason):
            return PrivilegedExecutableStatus(
                state: .unverifiable, path: path, foundVersion: nil, expectedVersion: expectedVersion,
                detail: "Root-owned copy \(path): version could not be verified (\(reason)); it will not be elevated."
            )
        case .version(let found):
            guard let expectedVersion else {
                return PrivilegedExecutableStatus(
                    state: .unchecked, path: path, foundVersion: found, expectedVersion: nil,
                    detail: "Root-owned copy \(path) is \(found); this host does not know its own "
                        + "release version, so the match was not checked."
                )
            }
            if found == expectedVersion {
                return PrivilegedExecutableStatus(
                    state: .matching, path: path, foundVersion: found, expectedVersion: expectedVersion,
                    detail: "Root-owned copy \(path) is \(found), matching this release (\(expectedVersion))."
                )
            }
            return PrivilegedExecutableStatus(
                state: .stale, path: path, foundVersion: found, expectedVersion: expectedVersion,
                detail: "Root-owned copy \(path) is \(found), but this release is \(expectedVersion); "
                    + "GUI fan control refuses it. Refresh it with `\(refreshCommand(for: path))`, or enable "
                    + "the optional fan helper."
            )
        }
    }

    /// Resolves `symcockpit` and refuses it unless the binary and every
    /// directory above it are root-owned and not group- or other-writable.
    ///
    /// The escaping in this file is already careful — `quoted form of` plus
    /// ``appleScriptStringLiteral`` — so the weakness was never *how* the
    /// command line is assembled but *which* binary gets selected. The shared
    /// resolver searches `PATH` and then a fallback list that includes
    /// `$HOME/.symaira/bin` and the Homebrew prefixes, several of which are
    /// writable without root on a normal Mac. An attacker with code execution
    /// as the user could drop a `symcockpit` there; the next fan change from
    /// the GUI would show the ordinary administrator prompt, and the user
    /// would authenticate that binary into root.
    static func resolveTrustedSymCockpit(
        resolve: () throws -> String = {
            try BoundedProcessRunner.resolvePrivilegedExecutablePath("symcockpit")
        }
    ) throws -> String {
        do {
            return try resolve()
        } catch let error as PrivilegedExecutableError {
            // A missing binary is an install problem the user already knows how
            // to fix; an untrustworthy one needs its exact failing condition
            // carried through, or the refusal is indistinguishable from a bug.
            if case .notFound = error {
                throw ElevationError.executableUnavailable
            }
            throw ElevationError.untrustedExecutable(error.description)
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
        let binaryPath = try resolveVerifiedSymCockpit()

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

    /// Starts `symcockpit <arguments>` as a *detached* root process behind
    /// one authorization prompt, and returns as soon as it is running.
    ///
    /// `runSymCockpit` waits for the command to finish, which is right for a
    /// one-shot write but wrong for `FanGovernor`, whose whole job is to keep
    /// running. Redirecting its standard streams and backgrounding it lets the
    /// shell `osascript` spawned exit immediately while the governor survives
    /// — so moving the fan control costs one password prompt, not one per
    /// sample. The governor re-reads its profile file every tick, so later
    /// changes of position need no prompt at all.
    ///
    /// Arguments are quoted exactly as in `runSymCockpit`; the only unquoted
    /// text is the fixed redirection-and-background suffix assembled here.
    public static func runSymCockpitDetached(_ arguments: [String]) throws {
        let binaryPath = try resolveVerifiedSymCockpit()

        let quotedParts = ([binaryPath] + arguments).map {
            "(quoted form of \(appleScriptStringLiteral($0)))"
        }
        let command = quotedParts.joined(separator: " & \" \" & ")
        let script = "do shell script \(command) & \" >/dev/null 2>&1 &\" "
            + "with administrator privileges"

        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeoutSeconds: 120
            )
        } catch {
            throw ElevationError.failed("could not launch the authorization prompt: \(error.localizedDescription)")
        }

        guard !result.timedOut else {
            throw ElevationError.failed("the authorization prompt did not finish in time")
        }
        guard result.terminationStatus == 0 else {
            let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""
            if stderrText.contains("User canceled") || stderrText.contains("(-128)") {
                throw ElevationError.cancelledByUser
            }
            throw ElevationError.failed(stderrText.isEmpty ? "privileged command failed" : stderrText)
        }
    }

    /// Whether *this exact process* currently has root — the only thing that
    /// makes a direct SMC write (or an unprivileged `powermetrics` call)
    /// succeed. A read-only SMC connection opens unprivileged and says
    /// nothing about write access; conflating the two previously made
    /// `doctor`/`permissions` claim fan control was available for GUI
    /// processes that could never actually write.
    public static var isRunningAsRoot: Bool { geteuid() == 0 }

    /// Whether a failed unprivileged SMC operation is worth retrying through
    /// elevation, as opposed to a hardware/platform mismatch a password
    /// prompt cannot fix. Deliberately wide: on at least one real machine,
    /// even `SMCService.isAvailable`'s read-only probe fails when
    /// unprivileged (every key, including ones that certainly exist, comes
    /// back "not found" rather than a clean permission error), so the
    /// resulting error can be a plain `TuneError.permission(...)` rather than
    /// a typed `FanControlError` — excluding anything but the two narrow
    /// `FanControlError` cases would silently never escalate on exactly the
    /// machines that need it. `SMCWritePolicy` safety checks (thermal
    /// emergency, AC power) re-evaluate fresh inside the elevated process, so
    /// widening this cannot bypass them.
    static func isWorthEscalating(_ error: Error) -> Bool {
        switch error {
        case let error as FanControlError:
            switch error {
            case .fanModeWriteRejected, .targetRPMWriteFailed:
                return true
            case .noFansDetected, .unsupportedPlatform:
                return false
            }
        default:
            return true
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

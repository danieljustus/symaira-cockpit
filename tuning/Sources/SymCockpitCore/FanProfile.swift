import Foundation

/// The three positions of the cockpit's fan control, left to right.
///
/// Position 0 is the Mac's own behavior — the cockpit writes nothing and the
/// firmware curve runs exactly as it does without this tool installed. The
/// two positions to the right hand fan speed to a `FanGovernor`, which keeps
/// sampling the CPU/GPU die temperature and moves the fans along this
/// profile's `curve`. Neither one pins the fans to a fixed speed: both stay
/// temperature-driven, so an idle Mac stays quiet on every setting and only
/// a hot one spins up.
public enum FanProfile: String, Codable, Sendable, CaseIterable {
    /// The Mac's factory behavior. No SMC write, no governor.
    case system

    /// Spins up earlier and climbs faster than the factory curve, to keep the
    /// chassis cool enough to keep on your lap under sustained load.
    case comfort

    /// The earliest, steepest curve — maximum sustained headroom before the
    /// chip has to throttle. Still temperature-driven: it reaches full speed
    /// only when the die is actually hot, and idles quietly.
    case performance

    /// Left-to-right order of the control.
    public static let ordered: [FanProfile] = [.system, .comfort, .performance]

    /// Position of this profile in the control, 0-based.
    public var step: Int { Self.ordered.firstIndex(of: self) ?? 0 }

    public static func at(step: Int) -> FanProfile {
        guard step >= 0, step < ordered.count else { return .system }
        return ordered[step]
    }

    public var displayName: String {
        switch self {
        case .system: return "Standard"
        case .comfort: return "Cool"
        case .performance: return "Max"
        }
    }

    /// One-line explanation shown under the control.
    public var summary: String {
        switch self {
        case .system:
            return "Your Mac's own fan curve — nothing is overridden."
        case .comfort:
            return "Fans start earlier and climb faster, to keep the chassis lap-cool."
        case .performance:
            return "Earliest, steepest curve for maximum sustained performance."
        }
    }
}

// MARK: - Persisted selection

/// The selected fan profile, persisted so the menu-bar control and the
/// privileged governor process agree on one answer.
///
/// The cockpit GUI (unprivileged, as the logged-in user) writes this file;
/// the governor (root) only ever reads it, and re-reads it every tick so a
/// change of position takes effect without a second password prompt. The
/// governor never writes here, so a root process never creates or modifies a
/// file in a user-writable directory. The only things a writer can express are
/// one of three enum cases and one Cool target clamped to
/// ``FanCoolTarget/range`` on write *and* on read (the target can only add
/// cooling), and every resulting SMC write still goes through
/// `SMCWritePolicy`'s clamps.
public struct FanProfileStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default location: `~/.symtune/fan-profile.json` for the *invoking*
    /// user — the person who owns the selection, not whatever account the
    /// process happens to be running as.
    ///
    /// The distinction is the whole point. The governor is started with
    /// `sudo`, and under `sudo` `homeDirectoryForCurrentUser` is `/var/root`:
    /// resolving it there makes the governor read a file that does not exist,
    /// see `.system`, and exit immediately without ever touching a fan. So
    /// when this process is root *because* someone elevated it, the profile
    /// is read from the account that did the elevating.
    ///
    /// A process that is root for some other reason has no invoking user to
    /// fall back to and gets root's own home; the cockpit app sidesteps the
    /// question entirely by passing `--state` explicitly.
    public static func defaultURL(home: URL? = nil) -> URL {
        let base = home ?? invokingUserHome()
        return base.appendingPathComponent(".symtune/fan-profile.json")
    }

    /// Test seam for ``invokingUserHome(environment:isRoot:)``.
    static func invokingUserHomeForTesting(
        environment: [String: String],
        isRoot: Bool
    ) -> URL {
        invokingUserHome(environment: environment, isRoot: isRoot)
    }

    /// Home directory of the user who invoked this process, seeing through a
    /// `sudo` elevation.
    static func invokingUserHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRoot: Bool = geteuid() == 0
    ) -> URL {
        guard isRoot,
              let sudoUser = environment["SUDO_USER"],
              let passwd = getpwnam(sudoUser),
              let dir = passwd.pointee.pw_dir
        else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: dir))
    }

    /// On-disk shape. `cool_target_celsius` is optional: a file written before
    /// the Cool target existed (just `{"profile": …}`) still decodes, and an
    /// absent key means "no target" — exactly the previous behaviour.
    private struct Payload: Codable {
        let profile: FanProfile
        let coolTargetCelsius: Double?

        enum CodingKeys: String, CodingKey {
            case profile
            case coolTargetCelsius = "cool_target_celsius"
        }
    }

    /// The stored profile, or `.system` when nothing is stored or the file is
    /// unreadable/corrupt — the safe default is always "don't override".
    public func read() -> FanProfile {
        readSelection().profile
    }

    /// The stored profile, throwing when it cannot be read or decoded. Callers
    /// that act on the value (reconciling a running helper) use this so a
    /// failure is not mistaken for the user choosing `.system`.
    public func readStrict() throws -> FanProfile {
        try readSelectionStrict().profile
    }

    /// The stored position and Cool target, or `.system` without a target when
    /// nothing is stored or the file is unreadable/corrupt.
    public func readSelection() -> FanSelection {
        (try? readSelectionStrict()) ?? .system
    }

    /// The stored position and Cool target, throwing when the file cannot be
    /// read or decoded. A target outside ``FanCoolTarget/range`` is clamped
    /// here, so a hand-edited file cannot exceed the bound; a non-finite or
    /// mistyped one makes the whole file corrupt rather than being guessed at.
    public func readSelectionStrict() throws -> FanSelection {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return FanSelection(profile: payload.profile, coolTargetCelsius: payload.coolTargetCelsius)
    }

    /// Selects `profile`, keeping the stored Cool target.
    public func write(_ profile: FanProfile) throws {
        let kept = (try? readSelectionStrict())?.coolTargetCelsius
        try writeSelection(FanSelection(profile: profile, coolTargetCelsius: kept))
    }

    /// Sets (clamped) or clears (`nil`) the Cool target, keeping the selected
    /// profile.
    public func writeCoolTarget(_ celsius: Double?) throws {
        let current = (try? readSelectionStrict())?.profile ?? .system
        try writeSelection(FanSelection(profile: current, coolTargetCelsius: celsius))
    }

    public func writeSelection(_ selection: FanSelection) throws {
        try StateFilePermissions.ensureDirectory(url.deletingLastPathComponent())
        let payload = Payload(
            profile: selection.profile,
            coolTargetCelsius: FanCoolTarget.sanitized(selection.coolTargetCelsius)
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
        StateFilePermissions.applyFilePermissions(at: url)
    }
}

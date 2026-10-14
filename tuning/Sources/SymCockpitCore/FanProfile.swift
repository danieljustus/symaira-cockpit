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

    /// The temperature→speed curve the governor follows, or nil for
    /// `.system`, which has no curve because it does not write at all.
    ///
    /// Fractions are of the fan's firmware maximum (`F{n}Mx`), and
    /// `SMCWritePolicy.targetRPM` floors the result at the firmware minimum
    /// (`F{n}Mn`) — on an M4 Pro that floor is about 0.30 of maximum, so a
    /// curve point below it simply means "idle speed".
    public var curve: FanCurve? {
        switch self {
        case .system:
            return nil
        case .comfort:
            return FanCurve(name: "Cool", points: [
                FanCurvePoint(temperatureC: 45, fraction: 0.30),
                FanCurvePoint(temperatureC: 55, fraction: 0.45),
                FanCurvePoint(temperatureC: 65, fraction: 0.60),
                FanCurvePoint(temperatureC: 75, fraction: 0.78),
                FanCurvePoint(temperatureC: 85, fraction: 1.00),
            ])
        case .performance:
            return FanCurve(name: "Max", points: [
                FanCurvePoint(temperatureC: 40, fraction: 0.35),
                FanCurvePoint(temperatureC: 50, fraction: 0.55),
                FanCurvePoint(temperatureC: 60, fraction: 0.72),
                FanCurvePoint(temperatureC: 70, fraction: 0.88),
                FanCurvePoint(temperatureC: 80, fraction: 1.00),
            ])
        }
    }
}

// MARK: - Governing temperature

extension FanProfile {
    /// SMC keys that report a CPU or GPU *die* temperature — the sensors the
    /// curve is driven from. Proximity, ambient, battery and enclosure
    /// sensors lag the die by tens of degrees and by many seconds, so a
    /// governor driven off them would spin up long after the chip needed it.
    ///
    /// `TCMz`/`TRDX` are the CPU and GPU die hotspots and `TCMb` the CPU
    /// core-max sensor (all verified on an M4 Pro); the Intel rows are the
    /// equivalent core/proximity sensors from `SMCService.intelTempKeys`.
    public static let dieTemperatureKeys: Set<String> = [
        "TCMz", "TCMb", "TRDX", "TG0P", "Ts0S",
        "TC0C", "TC1C", "TC2C", "TC3C", "TC4C",
        "TC5C", "TC6C", "TC7C", "TC8C", "TC9C", "TCXC", "TC0P",
    ]

    /// The temperature the curve is evaluated at: the hottest CPU/GPU die
    /// sensor in the report.
    ///
    /// Returns nil when the report carries no temperature at all, so callers
    /// hold the last target rather than treating "no reading" as "cold" and
    /// dropping the fans while the chip cooks. When the report has readings
    /// but none of them is a known die sensor, the hottest reading is used —
    /// an unfamiliar Mac still gets governed, just from a coarser sensor.
    public static func governingTemperature(in report: SensorReport) -> Double? {
        let dieMax = report.temperatures
            .filter { dieTemperatureKeys.contains($0.key) }
            .map(\.celsius)
            .max()
        return dieMax ?? report.temperatures.map(\.celsius).max()
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
/// file in a user-writable directory. The only thing a writer can express is
/// one of three enum cases, and every resulting SMC write still goes through
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

    private struct Payload: Codable {
        let profile: FanProfile
    }

    /// The stored profile, or `.system` when nothing is stored or the file is
    /// unreadable/corrupt — the safe default is always "don't override".
    public func read() -> FanProfile {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return .system }
        return payload.profile
    }

    public func write(_ profile: FanProfile) throws {
        try StateFilePermissions.ensureDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(Payload(profile: profile))
        try data.write(to: url, options: .atomic)
        StateFilePermissions.applyFilePermissions(at: url)
    }
}

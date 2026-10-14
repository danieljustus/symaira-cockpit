import Foundation

/// Keeps the fans on a `FanProfile`'s temperature curve.
///
/// The SMC has no "run this curve for me" register: once a fan is taken off
/// the firmware curve it holds whatever target RPM was last written to it. So
/// the two right-hand positions of the fan control are not a one-shot write —
/// they are this loop, sampling the CPU/GPU die temperature and re-writing the
/// target a few times a minute. That is also why the loop has to live in a
/// privileged process: only root may write the SMC, and re-authorizing every
/// five seconds is not a usable design.
///
/// The loop is deliberately *not* a fixed speed. On every profile the fans
/// still follow temperature — an idle Mac stays at its firmware minimum on
/// "Max" — so the firmware's own thermal protection is never displaced, only
/// pre-empted.
public struct FanGovernor: Sendable {
    /// How often the die temperature is resampled.
    public static let defaultInterval: TimeInterval = 5

    /// Fan speed is allowed to rise immediately but may only fall by this
    /// fraction of the range per tick. Die temperature drops the instant a
    /// burst of work ends, and following it down verbatim makes the fans
    /// audibly surge up and down; ramping down over ~15 seconds instead
    /// leaves the speed steady through short gaps in load.
    public static let maxDecreasePerTick = 0.05

    /// Changes smaller than this are not written at all, so a fan sitting at
    /// a stable temperature is left alone instead of taking an SMC write
    /// every tick.
    public static let deadband = 0.02

    private let fanControl: FanControlService
    private let sensors: SensorService
    private let config: TuneConfig
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        fanControl: FanControlService,
        sensors: SensorService,
        config: TuneConfig,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.fanControl = fanControl
        self.sensors = sensors
        self.config = config
        self.sleep = sleep
    }

    /// The fraction to write this tick.
    ///
    /// - `applied`: what was last written, or nil on the first tick.
    /// - `temperature`: the governing die temperature, or nil when the
    ///   sensors returned nothing this tick — in which case the last applied
    ///   value is held rather than treating "unknown" as "cold".
    ///
    /// Returns nil when nothing should be written: no curve (`.system`), no
    /// reading and nothing applied yet, or a change inside the deadband.
    public static func nextFraction(
        profile: FanProfile,
        temperature: Double?,
        applied: Double?
    ) -> Double? {
        guard let curve = profile.curve else { return nil }
        guard let temperature else { return applied }

        let target = curve.fraction(at: temperature)
        guard let applied else { return target }

        // Rise immediately, fall at a bounded rate.
        let next = target >= applied
            ? target
            : max(target, applied - maxDecreasePerTick)

        guard abs(next - applied) >= deadband || next >= 1.0 && applied < 1.0 else {
            return nil
        }
        return next
    }

    /// Run the governor until `shouldContinue` returns false or the selected
    /// profile becomes `.system`, then hand the fans back to the firmware.
    ///
    /// `profileProvider` is re-read every tick, so moving the control to
    /// another position takes effect without a second authorization prompt —
    /// the already-running root process simply picks up the new selection.
    ///
    /// The original per-fan mode and target are captured before the first
    /// write and restored on the way out, so exiting leaves the SMC exactly
    /// as it was found rather than at a guessed "auto" constant.
    public func run(
        profileProvider: @Sendable () -> FanProfile,
        shouldContinue: @Sendable () -> Bool = { true },
        onTick: (@Sendable (Double?, Double?) -> Void)? = nil
    ) throws {
        var applied: Double?
        // Captured lazily, immediately before the first write, and restored
        // only if there was one. A loop that never overrode anything — the
        // default position, or a stop before the first tick wrote — must
        // leave the SMC completely untouched rather than "restore" it to a
        // value it already held.
        var originals: [Int: (mode: UInt8?, targetRPM: Double?)]?
        defer {
            if let originals { fanControl.restore(originalStates: originals) }
        }

        while shouldContinue() {
            let profile = profileProvider()
            guard profile != .system else { return }

            let temperature = FanProfile.governingTemperature(in: sensors.read())
            if let next = Self.nextFraction(
                profile: profile,
                temperature: temperature,
                applied: applied
            ) {
                if originals == nil { originals = fanControl.captureOriginalStates() }
                try fanControl.applyFan(fraction: next, config: config)
                applied = next
            }
            onTick?(temperature, applied)

            sleep(Self.defaultInterval)
        }
    }
}


/// Thread-safe "stop requested" flag, set from a signal handler and read by
/// the governor loop.
final class FanGovernorStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

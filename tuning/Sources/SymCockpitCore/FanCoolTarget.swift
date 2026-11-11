import Foundation

/// The persisted fan selection: a position plus the optional Cool target.
///
/// This is what the governor consults every tick. It is deliberately tiny and
/// closed — one of three enum cases and one clamped number — so the only thing
/// a writer of the (user-writable) state file can express still ends up inside
/// `SMCWritePolicy`'s clamps.
public struct FanSelection: Sendable, Equatable {
    public var profile: FanProfile
    /// The stored Cool target in °C, already clamped to ``FanCoolTarget/range``.
    /// Kept even while another position is selected, so moving to Max and back
    /// to Cool does not lose the number.
    public var coolTargetCelsius: Double?

    public init(profile: FanProfile, coolTargetCelsius: Double? = nil) {
        self.profile = profile
        self.coolTargetCelsius = FanCoolTarget.sanitized(coolTargetCelsius)
    }

    public static let system = FanSelection(profile: .system)

    /// The target that actually influences the fans: only Cool has one.
    /// `.performance` and `.system` ignore it.
    public var effectiveCoolTarget: Double? {
        profile == .comfort ? coolTargetCelsius : nil
    }
}

/// The optional maximum average CPU/GPU temperature for the Cool position.
///
/// **It only ever adds cooling.** The governor takes the larger of the
/// default Cool curve (driven by the hottest die sensor, exactly as before)
/// and a copy of that curve shifted so that it reaches full speed at the
/// target, evaluated at the *average* cluster temperature. No target, or no
/// average this tick, means today's behaviour — never less cooling. The
/// firmware's own thermal protection stays in charge regardless.
public enum FanCoolTarget {
    /// Hard bounds, enforced on write and again on read.
    ///
    /// 85 °C is the point where the default Cool curve already reaches full
    /// speed, and an 85 °C *average* is a hot chip — a higher number would add
    /// nothing. Below 50 °C the average of an active chip is exceeded almost
    /// constantly, which would run the fans near full speed permanently.
    public static let range: ClosedRange<Double> = 50...85

    /// A finite value clamped into ``range``; nil for nil and non-finite input
    /// (NaN/∞ are a malformed target, never "the maximum").
    public static func sanitized(_ celsius: Double?) -> Double? {
        guard let celsius, celsius.isFinite else { return nil }
        return min(max(celsius, range.lowerBound), range.upperBound)
    }

    /// Whether `celsius` is inside the allowed range as typed (no clamping),
    /// used by the CLI and the UI to refuse instead of silently adjusting.
    public static func isWithinRange(_ celsius: Double) -> Bool {
        celsius.isFinite && range.contains(celsius)
    }

    /// The Cool curve shifted so it reaches full speed at `target`.
    ///
    /// Points: (T-40, 0.30), (T-30, 0.45), (T-20, 0.60), (T-10, 0.78), (T, 1.00)
    /// — the default Cool curve's shape, which spans 45…85 °C, moved left by
    /// `85 - T`. At T = 85 it is the default curve itself.
    public static func curve(target: Double) -> FanCurve {
        let t = sanitized(target) ?? range.upperBound
        return FanCurve(name: "Cool target", points: [
            FanCurvePoint(temperatureC: t - 40, fraction: 0.30),
            FanCurvePoint(temperatureC: t - 30, fraction: 0.45),
            FanCurvePoint(temperatureC: t - 20, fraction: 0.60),
            FanCurvePoint(temperatureC: t - 10, fraction: 0.78),
            FanCurvePoint(temperatureC: t, fraction: 1.00),
        ])
    }

    // MARK: - Average cluster temperature

    /// CPU performance-core rows (`Tp01`…`Tp12`) and E-core cluster rows
    /// (`Te04`…`Te0T`): four characters, `Tp`/`Te` plus two.
    private static func isAppleSiliconClusterKey(_ key: String) -> Bool {
        key.utf8.count == 4 && (key.hasPrefix("Tp") || key.hasPrefix("Te"))
    }

    /// Intel per-core rows `TC0C`…`TC9C` and `TCXC`.
    private static let intelCoreKeys: Set<String> = [
        "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C", "TC9C", "TCXC",
    ]

    /// GPU rows: `Tg*` per-cluster keys where a Mac publishes them, the GPU
    /// die probe `TG0P`, and `TRDX`. On Apple Silicon `TRDX` (the GPU die
    /// reading) is the only GPU sensor there is, so it is the GPU's one vote;
    /// leaving it out would make a GPU-bound load invisible to the average.
    private static func isGPUClusterKey(_ key: String) -> Bool {
        key == "TG0P" || key == "TRDX" || (key.utf8.count == 4 && key.hasPrefix("Tg"))
    }

    /// The CPU die hotspot. It is an aggregate of the cores, not a cluster:
    /// mixed into a per-cluster mean it would count the hottest spot twice. It
    /// stands in only when a Mac publishes no CPU core/cluster row at all, so
    /// the feature degrades instead of vanishing. (`TCMb`, the core-max row,
    /// is never used.)
    private static let cpuHotspotFallbackKey = "TCMz"

    /// The mean of every plausible CPU and GPU *cluster* temperature in
    /// `report` — the number the Cool target is compared against.
    ///
    /// Included by key family: CPU cores/clusters (`Tp**`, `Te**`, Intel
    /// `TC#C`) and GPU rows (`Tg**`, `TG0P`, `TRDX`). Excluded on purpose:
    /// proximity (`TCHP`, `TC0P`, `TM0P`), ambient (`Ta0P`, `TA0P`), the SoC
    /// probe (`Ts0S`), battery and anything unknown, plus the CPU aggregates
    /// `TCMb` (core max, never) and `TCMz` (CPU die hotspot, only while no CPU
    /// core/cluster row exists).
    /// Every reading must also be physically plausible
    /// (`SMCService.plausibleTemperatureRange`): an M4 Pro implements
    /// `Tp01`–`Tp09` and reads them back at 0–8 °C while the die is at 85 °C,
    /// and averaging those in would cool the Mac less, not more.
    ///
    /// The mean is flat — every qualifying sensor counts once — so it is what
    /// a person gets by averaging the cluster rows of `symcockpit sensors`.
    ///
    /// Returns nil when no qualifying reading exists.
    public static func averageClusterTemperature(in report: SensorReport) -> Double? {
        let plausible = report.temperatures.filter {
            $0.celsius.isFinite && SMCService.isPlausibleTemperature($0.celsius)
        }
        let cpu = plausible.filter {
            isAppleSiliconClusterKey($0.key) || intelCoreKeys.contains($0.key)
        }
        let gpu = plausible.filter { isGPUClusterKey($0.key) }
        let cpuUsed = cpu.isEmpty
            ? plausible.filter { $0.key == cpuHotspotFallbackKey }
            : cpu
        let used = cpuUsed + gpu
        guard !used.isEmpty else { return nil }
        return used.map(\.celsius).reduce(0, +) / Double(used.count)
    }

    // MARK: - Control law

    /// The fraction to run the fans at for `profile` this tick, or nil when
    /// the profile has no curve (`.system`) or there is no governing reading.
    ///
    /// `max(default curve at the hottest die, target curve at the average)`:
    /// the target can raise the answer but never lower it, so a missing or
    /// out-of-date average, a wrong target, or no target at all can only
    /// produce today's behaviour.
    public static func targetFraction(
        profile: FanProfile,
        temperature: Double?,
        coolTarget: Double?,
        averageTemperature: Double?
    ) -> Double? {
        guard let curve = profile.curve, let temperature else { return nil }
        var fraction = curve.fraction(at: temperature)
        if profile == .comfort,
           let target = sanitized(coolTarget),
           let average = averageTemperature, average.isFinite {
            fraction = max(fraction, self.curve(target: target).fraction(at: average))
        }
        return fraction
    }
}

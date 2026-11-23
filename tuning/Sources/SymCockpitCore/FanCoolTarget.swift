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
}

import Foundation

/// Hardware-safety guardrails. Every write path (brightness, dim, fan, charge
/// limit) MUST route its requested value through this policy before applying.
///
/// Two non-negotiable rules for anything that touches the SMC or display:
///   1. Clamp to a safe range — never pass an unbounded user/agent value to
///      hardware.
///   2. Never disable thermal protection. Fan control may only *raise* the
///      effective floor above the firmware's automatic curve, never silence it.
///
/// The controller is additionally responsible for *restore-on-exit*: any value
/// it overrides during a session is reset to the system default when the
/// process terminates normally.
public enum SafetyPolicy: Sendable {
    // MARK: Extended / EDR brightness (multiplier over the 100% SDR reference).
    public static let extendedBrightnessMin = 1.0
    public static let extendedBrightnessMax = 1.6

    // MARK: Software dim overlay (1.0 = no dimming, 0.0 = fully black).
    /// Floored above 0 so the agent/user can never blank the screen entirely.
    public static let dimMin = 0.15
    public static let dimMax = 1.0

    // MARK: Built-in hardware brightness (0.0–1.0).
    public static let brightnessMin = 0.0
    public static let brightnessMax = 1.0

    // MARK: Fan speed, expressed as a fraction (0.0–1.0) of the fan's range.
    /// The firmware's automatic curve is always honored as a lower bound; this
    /// fraction can only push the fan *faster*, never below the auto target.
    public static let fanFractionMin = 0.0
    public static let fanFractionMax = 1.0
    /// Soft floor for manual fan requests. Even if the user asks for 0.0, the
    /// effective fraction is floored here to avoid completely silencing fans.
    public static let fanSpeedFloor = 0.15

    // MARK: Battery charge limit (percent).
    public static let chargeLimitMin = 50
    public static let chargeLimitMax = 100
    /// Hysteresis band used by the charge-limit controller: re-allow charging
    /// only when the battery has dropped this far below the target.
    public static let chargeLimitHysteresis = 5
    /// Upper clamp for the user-configurable hysteresis value.
    public static let chargeLimitHysteresisMax = 20

    // MARK: Thermal emergency threshold.
    /// If any die sensor exceeds this temperature, manual fan writes are
    /// refused and existing overrides are restored. This is a last-resort
    /// guardrail; the firmware's own thermal protection always takes precedence.
    public static let thermalOverrideCelsius = 90.0

    // MARK: Adapter check for charge limiting.
    /// Refuse to inhibit charging unless the Mac is on AC power. Inhibiting
    /// charge while running on battery can cause an unexpected shutdown.
    public static let requireACForChargeLimit = true

    /// Clamp `value` into the inclusive `[lower, upper]` range.
    public static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}

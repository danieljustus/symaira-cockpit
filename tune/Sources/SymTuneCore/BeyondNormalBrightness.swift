import Foundation

/// The mapping behind the popover's single center-anchored brightness control.
///
/// Software dimming and EDR headroom are the two things symtune can do that the
/// display cannot do on its own: dim below the backlight's native minimum, and
/// push above 100% SDR. Presented as two separate sliders they read like two
/// more ways to set brightness. Presented as one control anchored at the
/// middle, the shape says what they are — *centre is exactly what the display
/// would show without symtune, and every deviation is the range symtune adds*.
///
/// Position runs `-1...1`:
/// - `-1` is maximum software dimming (the darkest the policy allows)
/// - `0` is untouched — no dim overlay, no EDR headroom
/// - `+1` is maximum extended brightness (the brightest the policy allows)
///
/// The OS backlight level is deliberately *not* part of this. It is a third,
/// independent axis that macOS already owns, and folding it in would make the
/// centre mean "some particular backlight level" instead of "no change".
public struct BeyondNormalBrightness: Equatable, Sendable {

    /// Dim factor as ``DimOverlay`` wants it: `1.0` is no dimming, smaller is
    /// darker, floored by ``TuneConfig/dimMin``.
    public let dimFactor: Double

    /// EDR headroom multiplier: `1.0` is no extra headroom, up to
    /// ``TuneConfig/extendedBrightnessMax``.
    public let extendedBrightness: Double

    public init(dimFactor: Double, extendedBrightness: Double) {
        self.dimFactor = dimFactor
        self.extendedBrightness = extendedBrightness
    }

    /// Neither side engaged — the display as the OS alone would drive it.
    public static let normal = BeyondNormalBrightness(dimFactor: 1.0, extendedBrightness: 1.0)

    /// The slider's own range.
    public static let positionRange: ClosedRange<Double> = -1.0...1.0

    // MARK: - Position → hardware values

    /// Resolve a slider position into the dim and EDR values to apply.
    ///
    /// Only one side is ever engaged: moving left resets EDR headroom to `1.0`,
    /// moving right lifts the dim overlay. Otherwise a leftover value from the
    /// other half would silently keep acting.
    ///
    /// - Parameters:
    ///   - position: slider position, clamped into ``positionRange``.
    ///   - config: supplies the per-side safety clamps, which still apply
    ///     exactly as they did to the two separate sliders.
    ///   - allowsExtendedBrightness: `false` on a display with no EDR
    ///     headroom, which pins the positive half to centre.
    public static func resolve(
        position: Double,
        config: TuneConfig,
        allowsExtendedBrightness: Bool = true
    ) -> BeyondNormalBrightness {
        let clamped = min(max(position, -1.0), 1.0)

        if clamped < 0 {
            // Full left reaches dimMin; the overlay is never allowed to black
            // the screen out entirely, which is what dimMin is protecting.
            let span = 1.0 - config.dimMin
            let factor = 1.0 - (-clamped * span)
            return BeyondNormalBrightness(
                dimFactor: min(max(factor, config.dimMin), config.dimMax),
                extendedBrightness: 1.0
            )
        }

        if clamped > 0, allowsExtendedBrightness {
            let span = config.extendedBrightnessMax - 1.0
            let value = 1.0 + clamped * span
            return BeyondNormalBrightness(
                dimFactor: 1.0,
                extendedBrightness: min(
                    max(value, config.extendedBrightnessMin),
                    config.extendedBrightnessMax
                )
            )
        }

        return .normal
    }

    // MARK: - Hardware values → position

    /// Where the knob sits for the currently applied overrides.
    ///
    /// Used to seed the control from whatever state the app is already in,
    /// including overrides applied from the CLI or a profile.
    public static func position(
        dimFactor: Double?,
        extendedBrightness: Double?,
        config: TuneConfig
    ) -> Double {
        // Dimming wins when both are somehow set: it is the more visible of the
        // two, so the knob should sit where the user can see its effect.
        if let dimFactor, dimFactor < 1.0 {
            let span = 1.0 - config.dimMin
            guard span > 0 else { return 0 }
            return -min((1.0 - dimFactor) / span, 1.0)
        }

        if let extendedBrightness, extendedBrightness > 1.0 {
            let span = config.extendedBrightnessMax - 1.0
            guard span > 0 else { return 0 }
            return min((extendedBrightness - 1.0) / span, 1.0)
        }

        return 0
    }

    // MARK: - Readout

    /// The trailing readout for a slider position: `Normal`, `Dim 40%` or
    /// `Bright +25%`, so the label states which side of centre is engaged
    /// rather than leaving a bare signed number to be interpreted.
    public static func readout(position: Double) -> String {
        let clamped = min(max(position, -1.0), 1.0)
        if abs(clamped) < 0.005 { return "Normal" }
        let percent = Int((abs(clamped) * 100).rounded())
        return clamped < 0 ? "Dim \(percent)%" : "Bright +\(percent)%"
    }
}

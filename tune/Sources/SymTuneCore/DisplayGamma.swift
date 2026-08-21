@preconcurrency import AppKit

/// One display's gamma transfer table (the hardware LUT CoreGraphics applies
/// after colour management).
///
/// Values are normally in `0...1`, where the identity ramp maps every input to
/// itself. Values **above** `1.0` are the mechanism behind extended brightness:
/// with EDR engaged on the display, an output of `1.3` renders 30% brighter
/// than SDR white instead of clipping — see ``DisplayGammaController``.
public struct GammaRamp: Equatable, Sendable {
    public var red: [CGGammaValue]
    public var green: [CGGammaValue]
    public var blue: [CGGammaValue]

    public init(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Number of samples per channel (`0` for an empty ramp).
    public var sampleCount: Int { red.count }

    /// The straight ramp: input maps to output unchanged.
    public static func identity(sampleCount: Int = 256) -> GammaRamp {
        precondition(sampleCount > 1, "a gamma ramp needs at least two samples")
        let values = (0..<sampleCount).map { CGGammaValue($0) / CGGammaValue(sampleCount - 1) }
        return GammaRamp(red: values, green: values, blue: values)
    }

    /// Whether every channel has the same, non-zero sample count.
    public var isWellFormed: Bool {
        red.count > 1 && red.count == green.count && red.count == blue.count
    }
}

/// Pure gamma math: how warmth and an extended-brightness boost combine into
/// one table.
///
/// Both features write the *same* hardware LUT, so they cannot each own it.
/// They used to: warmth replaced the table with a freshly built linear ramp,
/// which discarded the display's own calibration curve — the screen changed
/// appearance even at "neutral" warmth. Here both are expressed as multipliers
/// **on top of the table the display already had**, so neutral input reproduces
/// the captured base ramp exactly.
public enum GammaComposition: Sendable {

    /// Green attenuation at full warmth. Small: green carries most of the
    /// luminance, so pulling it hard reads as "dimmer", not "warmer".
    public static let warmthGreenAttenuation: Float = 0.05
    /// Blue attenuation at full warmth — the actual colour-temperature shift.
    public static let warmthBlueAttenuation: Float = 0.30

    /// Compose the captured base ramp with a warmth shift and a brightness boost.
    ///
    /// - Parameters:
    ///   - base: the display's own table, as captured before any override.
    ///   - warmth: `0` neutral … `1` warmest.
    ///   - boost: `1.0` no boost; `>1.0` pushes output above SDR white and
    ///     requires EDR to be engaged on that display to be visible.
    /// - Returns: the table to hand to CoreGraphics, or `nil` if `base` is
    ///   malformed (an empty or ragged ramp must never reach the hardware).
    public static func compose(base: GammaRamp, warmth: Float, boost: Float) -> GammaRamp? {
        guard base.isWellFormed else { return nil }

        let warmthFactor = min(max(warmth, 0), 1)
        let boostFactor = max(boost, 0)
        let greenScale = boostFactor * (1 - warmthFactor * warmthGreenAttenuation)
        let blueScale = boostFactor * (1 - warmthFactor * warmthBlueAttenuation)
        // Headroom for the whole table: 1.0 normally, `boost` when boosting.
        // Clamping to 1.0 here is what silently disabled extended brightness.
        let ceiling = max(1.0, boostFactor)

        func scale(_ channel: [CGGammaValue], _ factor: Float) -> [CGGammaValue] {
            channel.map { min(max($0 * factor, 0), ceiling) }
        }

        return GammaRamp(
            red: scale(base.red, boostFactor),
            green: scale(base.green, greenScale),
            blue: scale(base.blue, blueScale)
        )
    }

    /// Whether `warmth`/`boost` mean "leave the display alone", in which case
    /// the caller should restore the system table instead of writing one.
    public static func isNeutral(warmth: Float, boost: Float) -> Bool {
        warmth <= 0.0005 && abs(boost - 1.0) <= 0.0005
    }
}

// MARK: - Hardware access

/// Seam over the four CoreGraphics gamma calls, so the controller's state
/// machine is testable without a display session.
public protocol GammaIO: Sendable {
    /// Read the display's current table.
    func readRamp(displayID: CGDirectDisplayID, sampleCount: Int) -> GammaRamp?
    /// Write a table. Returns `false` when CoreGraphics rejected it.
    func writeRamp(_ ramp: GammaRamp, displayID: CGDirectDisplayID) -> Bool
    /// Hand every display back to its ColorSync calibration.
    func restoreSystemRamps()
}

/// Production implementation talking to CoreGraphics.
public struct CoreGraphicsGammaIO: GammaIO {
    public init() {}

    public func readRamp(displayID: CGDirectDisplayID, sampleCount: Int) -> GammaRamp? {
        var red = [CGGammaValue](repeating: 0, count: sampleCount)
        var green = red
        var blue = red
        var written: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            displayID, UInt32(sampleCount), &red, &green, &blue, &written
        )
        guard result == .success, written > 1 else { return nil }
        let count = Int(written)
        return GammaRamp(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }

    public func writeRamp(_ ramp: GammaRamp, displayID: CGDirectDisplayID) -> Bool {
        guard ramp.isWellFormed else { return false }
        var red = ramp.red
        var green = ramp.green
        var blue = ramp.blue
        return CGSetDisplayTransferByTable(
            displayID, UInt32(ramp.sampleCount), &red, &green, &blue
        ) == .success
    }

    public func restoreSystemRamps() {
        CGDisplayRestoreColorSyncSettings()
    }
}

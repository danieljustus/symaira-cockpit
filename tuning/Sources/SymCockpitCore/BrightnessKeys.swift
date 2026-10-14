import Foundation

/// Who answers the brightness keys (issue #250).
///
/// The default is the system, always: intercepting a hardware key is exactly
/// the kind of change that must be asked for rather than inherited from an
/// update.
public enum BrightnessKeyHandling: String, CaseIterable, Sendable {
    /// macOS handles F1/F2 as it always has. Nothing is intercepted.
    case system
    /// The keys are consumed before macOS sees them, brightness is set
    /// directly, and the readout comes from this app's own HUD.
    case cockpit

    public var displayName: String {
        switch self {
        case .system: "Standard"
        case .cockpit: "SymCockpit"
        }
    }
}

/// Reading the brightness-key preference out of stored defaults.
///
/// The key sits in the grandfathered `com.symaira.symtune` namespace, which
/// must not be renamed (see `AGENTS.md`). Resolution is pure so the default —
/// the part that matters — is checkable without a `UserDefaults`.
public enum BrightnessKeyDefaults {
    public static let handlingKey = "com.symaira.symtune.brightnessKeys.handling"

    /// The stored preference, or the system default.
    ///
    /// An unset, empty or unrecognised value resolves to ``BrightnessKeyHandling/system``:
    /// when the stored state cannot be trusted, the answer is to leave the keys
    /// alone.
    public static func resolve(storedHandling: String?) -> BrightnessKeyHandling {
        guard let storedHandling,
              let handling = BrightnessKeyHandling(rawValue: storedHandling)
        else { return .system }
        return handling
    }
}

/// The arithmetic behind one brightness key press.
///
/// macOS moves brightness in sixteenths, and quarters that when Shift+Option is
/// held. Replacing the system's handling means reproducing both, plus the
/// detail that makes it feel right: the step is taken from the value the
/// display actually holds, snapped onto the step grid first. A press that
/// starts off-grid — auto-brightness, Control Center, a fine-adjust earlier —
/// otherwise carries that offset forever.
public enum BrightnessKeyStep {
    /// The step for a plain key press: one sixteenth.
    public static let coarse: Float = 1.0 / 16.0
    /// The Shift+Option step: a quarter of ``coarse``.
    public static let fine: Float = 1.0 / 64.0

    public enum Direction: Sendable {
        case up, down

        var sign: Float {
            switch self {
            case .up: 1
            case .down: -1
            }
        }
    }

    /// The level one key press moves to, from the display's current level.
    ///
    /// - Parameters:
    ///   - current: the level read off the display, 0...1.
    ///   - direction: which key was pressed.
    ///   - fine: whether Shift+Option was held.
    /// - Returns: the target level, snapped to the step grid and clamped
    ///   to 0...1.
    public static func next(
        from current: Float,
        direction: Direction,
        fine: Bool
    ) -> Float {
        let grid = fine ? Self.fine : Self.coarse
        let snapped = (min(1, max(0, current)) / grid).rounded() * grid
        return min(1, max(0, snapped + direction.sign * grid))
    }

    /// How many segments of a `count`-segment bar are lit at `level`.
    ///
    /// The system HUD quantises its bar the same way, so a level between two
    /// steps still reads as a whole number of segments.
    public static func filledSegments(for level: Float, of count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(1, max(0, level))
        return min(count, max(0, Int((clamped * Float(count)).rounded())))
    }
}

import Foundation

/// Where the live metrics readout appears (issue #251).
///
/// One surface at a time, not two switches: the menu-bar status item and the
/// notch HUD show the same numbers, and running both meant the same readout
/// twice, a few pixels apart.
public enum ReadoutSurface: String, CaseIterable, Sendable {
    /// The menu-bar status item — the default, and the only option on a Mac
    /// without a camera cutout.
    case menuBar
    /// The HUD around the camera cutout, with the status item hidden.
    case notch

    public var displayName: String {
        switch self {
        case .menuBar: "Menu bar"
        case .notch: "Notch"
        }
    }
}

/// Reading the surface preference out of stored defaults, including the
/// migration from the switch that preceded it.
///
/// The keys live in the grandfathered `com.symaira.symtune` namespace, which
/// must not be renamed (see `AGENTS.md`): ``legacyNotchEnabledKey`` is the
/// boolean issue #224 shipped, and it stays readable so an upgrade lands on the
/// surface the user had already chosen instead of silently reverting.
///
/// The resolution is pure so it can be checked without a `UserDefaults`, a
/// screen, or a running app.
public enum ReadoutSurfaceDefaults {
    /// Where the choice is stored from #251 onwards.
    public static let surfaceKey = "com.symaira.symtune.readoutSurface"
    /// The boolean #224 stored. Read for migration, and still written, so
    /// moving back to an older build finds the state it understands.
    public static let legacyNotchEnabledKey = "com.symaira.symtune.notchHUD.enabled"

    /// The stored preference, or the migrated legacy value, or the default.
    ///
    /// - Parameters:
    ///   - storedSurface: raw value under ``surfaceKey``, `nil` when unset.
    ///   - legacyNotchEnabled: the value under ``legacyNotchEnabledKey``;
    ///     `UserDefaults.bool(forKey:)` reports `false` for an unset key, which
    ///     is exactly the wanted default.
    public static func resolve(
        storedSurface: String?,
        legacyNotchEnabled: Bool
    ) -> ReadoutSurface {
        if let storedSurface, let surface = ReadoutSurface(rawValue: storedSurface) {
            return surface
        }
        // Either never set, or written by a version that did not know the key.
        // The old switch is the only evidence of what the user asked for.
        return legacyNotchEnabled ? .notch : .menuBar
    }

    /// The surface that can actually be shown right now.
    ///
    /// A stored `.notch` on a Mac whose menu-bar display has no cutout — a Mac
    /// mini, an external monitor, a lid-closed MacBook — would leave the app
    /// with no visible surface at all and no way back to its own preferences.
    /// The choice is kept; only the rendering falls back.
    public static func effective(
        _ surface: ReadoutSurface,
        notchAvailable: Bool
    ) -> ReadoutSurface {
        switch surface {
        case .menuBar: .menuBar
        case .notch: notchAvailable ? .notch : .menuBar
        }
    }
}

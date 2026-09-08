import Combine
import Foundation
import SymTuneCore

/// Which surface shows the live readout — menu bar or notch (issue #251,
/// replacing the additive switch from #224).
///
/// `UserDefaults`-backed rather than part of `config.toml`, for the same reason
/// the AI-usage switches are: this is a property of one GUI surface on one
/// machine, not of the tuning configuration the CLI shares. The keys sit in the
/// grandfathered `com.symaira.symtune` namespace, which must not be renamed.
///
/// Defaults to the menu bar. The notch HUD draws over the menu bar, and nothing
/// that does that should appear without being asked for.
@MainActor
final class ReadoutSurfacePreferences: ObservableObject {
    @Published var surface: ReadoutSurface {
        didSet {
            defaults.set(surface.rawValue, forKey: ReadoutSurfaceDefaults.surfaceKey)
            // Kept in step so downgrading to a build that only knows the old
            // boolean lands on the same surface instead of reverting.
            defaults.set(
                surface == .notch,
                forKey: ReadoutSurfaceDefaults.legacyNotchEnabledKey
            )
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.surface = ReadoutSurfaceDefaults.resolve(
            storedSurface: defaults.string(forKey: ReadoutSurfaceDefaults.surfaceKey),
            legacyNotchEnabled: defaults.bool(forKey: ReadoutSurfaceDefaults.legacyNotchEnabledKey)
        )
    }
}

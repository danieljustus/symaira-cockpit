import Combine
import Foundation

/// Whether the notch HUD runs (issue #224).
///
/// `UserDefaults`-backed rather than part of `config.toml`, for the same reason
/// the AI-usage switches are: this is a property of one GUI surface on one
/// machine, not of the tuning configuration the CLI shares. The key sits in the
/// grandfathered `com.symaira.symtune` namespace, which must not be renamed.
///
/// Defaults to **off**. The HUD draws over the menu bar, and nothing that does
/// that should appear without being asked for.
@MainActor
final class NotchHUDPreferences: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "com.symaira.symtune.notchHUD.enabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Keys.enabled)
    }
}

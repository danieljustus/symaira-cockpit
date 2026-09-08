import Combine
import Foundation
import SymTuneCore

/// Who answers the brightness keys — macOS or this app (issue #250).
///
/// `UserDefaults`-backed rather than part of `config.toml`, for the same reason
/// the readout surface is: this is a property of one GUI surface on one
/// machine, not of the tuning configuration the CLI shares. The key sits in the
/// grandfathered `com.symaira.symtune` namespace, which must not be renamed.
///
/// Defaults to the system. Nothing about an update should quietly start
/// intercepting a hardware key.
@MainActor
final class BrightnessKeyPreferences: ObservableObject {
    @Published var handling: BrightnessKeyHandling {
        didSet {
            defaults.set(handling.rawValue, forKey: BrightnessKeyDefaults.handlingKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.handling = BrightnessKeyDefaults.resolve(
            storedHandling: defaults.string(forKey: BrightnessKeyDefaults.handlingKey)
        )
    }
}

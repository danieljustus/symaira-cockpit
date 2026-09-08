import Combine
import Foundation
import SymTuneCore

/// Where the HUD is docked — the camera cutout, or either screen edge at one of
/// three heights.
///
/// `UserDefaults`-backed for the same reason ``ReadoutSurfacePreferences`` is:
/// this is a property of one GUI surface on one machine, not of the tuning
/// configuration the CLI shares. The key sits in the grandfathered
/// `com.symaira.symtune` namespace, which must not be renamed.
///
/// Defaults to ``HUDDock/notch``, which is where the HUD lived before it could
/// be moved — an upgrade must not relocate a HUD the user had already placed.
@MainActor
final class HUDDockPreferences: ObservableObject {
    static let dockKey = "com.symaira.symtune.hud.dock"

    @Published var dock: HUDDock {
        didSet {
            guard dock != oldValue else { return }
            defaults.set(dock.storageKey, forKey: Self.dockKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dock = defaults.string(forKey: Self.dockKey)
            .flatMap(HUDDock.init(storageKey:))
            ?? .notch
    }
}

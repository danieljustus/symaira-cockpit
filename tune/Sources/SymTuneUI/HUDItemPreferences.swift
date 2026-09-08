import SwiftUI
import Combine
import Foundation
import SymTuneCore

/// What the HUD shows, where, and how far it has to be open before it does.
///
/// `UserDefaults`-backed for the same reason ``HUDDockPreferences`` and
/// ``ReadoutSurfacePreferences`` are: this describes one GUI surface on one
/// machine, not the tuning configuration `config.toml` shares with the CLI. The
/// key sits in the grandfathered `com.symaira.symtune` namespace, which must
/// not be renamed (see `AGENTS.md`).
///
/// Nothing stored means ``HUDItemLayout/default`` — the placement that
/// reproduces the two-readout HUD this replaced, so an upgrade changes what the
/// user sees only once they change it themselves. An *empty* stored list is a
/// different thing and is preserved: that is somebody who switched every item
/// off, and a HUD that quietly repopulated itself on the next launch would be
/// worse than one that stays blank.
@MainActor
final class HUDItemPreferences: ObservableObject {
    static let itemsKey = "com.symaira.symtune.hud.items"

    @Published var layout: HUDItemLayout {
        didSet {
            guard layout != oldValue else { return }
            defaults.set(layout.storageValues, forKey: Self.itemsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.layout = HUDItemLayout(
            storageValues: defaults.array(forKey: Self.itemsKey) as? [String]
        ) ?? .default
    }

    /// The placement for one item, as a binding the settings rows can drive.
    ///
    /// Writing through the binding replaces the whole layout, which is what
    /// makes the single `didSet` above the only place that persists — there is
    /// no path that changes a placement without writing it.
    func placement(for kind: HUDItemKind) -> Binding<HUDItemPlacement> {
        Binding(
            get: { self.layout.placement(for: kind) },
            set: { self.layout.set($0, for: kind) }
        )
    }

    /// Put the HUD back to the placement it ships with.
    func resetToDefault() {
        layout = .default
    }
}

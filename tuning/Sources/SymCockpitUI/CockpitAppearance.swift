import AppKit
import Observation
import SymairaTheme

public typealias CockpitAppearance = SymairaAppearance

/// One GUI-only choice for windows, popovers, native controls and menus.
/// A nil store keeps passive previews entirely in memory.
@MainActor @Observable
public final class CockpitAppearancePreferences {
    static let storageKey = "com.symaira.symtune.appearance"
    @ObservationIgnored private let defaults: UserDefaults?

    public var selection: CockpitAppearance {
        didSet {
            guard selection != oldValue else { return }
            defaults?.set(selection.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

    public init(defaults: UserDefaults? = .standard, initialValue: CockpitAppearance = .system) {
        self.defaults = defaults
        self.selection = defaults?.string(forKey: Self.storageKey)
            .flatMap(CockpitAppearance.init(rawValue:)) ?? initialValue
    }

    public func apply() {
        // nil restores live macOS following, not a snapshot of its current mode.
        selection.apply()
    }
}

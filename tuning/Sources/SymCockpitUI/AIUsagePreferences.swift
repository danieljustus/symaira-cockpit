import Foundation
import Combine
import SymCockpitCore

/// AI-usage preferences for the menu-bar app.
///
/// UserDefaults-backed; every provider toggle defaults to **off** so no
/// network call happens until the user explicitly enables a provider.
@MainActor
final class AIUsagePreferences: ObservableObject {
    /// Providers the user enabled (default: none).
    @Published var enabledProviders: Set<String> {
        didSet { defaults.set(Array(enabledProviders), forKey: Keys.enabledProviders) }
    }

    /// Refresh interval in seconds (default 5 minutes).
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    /// Whether the menu bar shows a compact AI usage readout.
    @Published var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: Keys.menuBarEnabled) }
    }

    // MARK: - Display options (issue #361)

    /// When true, the menu bar shows the currently active provider's usage
    /// prominently (pinned) rather than a compact summary.
    @Published var displayPinnedProvider: Bool {
        didSet { defaults.set(displayPinnedProvider, forKey: Keys.displayPinnedProvider) }
    }

    /// When true, the user can drag providers to reorder them in the UI.
    @Published var displayAllowReorder: Bool {
        didSet { defaults.set(displayAllowReorder, forKey: Keys.displayAllowReorder) }
    }

    /// When true, providers with no configured credentials are hidden from
    /// the preferences list and menu bar readout.
    @Published var displayHideUnconfigured: Bool {
        didSet { defaults.set(displayHideUnconfigured, forKey: Keys.displayHideUnconfigured) }
    }

    /// Provider display order (user-reordered). Empty falls back to catalog order.
    @Published var displayOrder: [String] {
        didSet { defaults.set(displayOrder, forKey: Keys.displayOrder) }
    }

    /// Visibility overrides per provider ID (`.hidden` or `.shown`).
    @Published var displayVisibility: [String: Bool] {
        didSet { defaults.set(displayVisibility, forKey: Keys.displayVisibility) }
    }

    /// Custom SymVault entry path per provider ID (issue #376). Opaque paths
    /// only — never a secret. A provider without an entry uses the default
    /// `symtune/<provider>`.
    @Published private(set) var vaultEntryPaths: [String: String] {
        didSet { defaults.set(vaultEntryPaths, forKey: Keys.vaultEntryPaths) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let enabledProviders = "com.symaira.symtune.aiUsage.enabledProviders"
        static let refreshInterval = "com.symaira.symtune.aiUsage.refreshInterval"
        static let menuBarEnabled = "com.symaira.symtune.aiUsage.menuBarEnabled"
        static let displayPinnedProvider = "com.symaira.symtune.aiUsage.displayPinnedProvider"
        static let displayAllowReorder = "com.symaira.symtune.aiUsage.displayAllowReorder"
        static let displayHideUnconfigured = "com.symaira.symtune.aiUsage.displayHideUnconfigured"
        static let displayOrder = "com.symaira.symtune.aiUsage.displayOrder"
        static let displayVisibility = "com.symaira.symtune.aiUsage.displayVisibility"
        static let vaultEntryPaths = SymVaultEntryPaths.defaultsKey
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabledProviders = Set(defaults.stringArray(forKey: Keys.enabledProviders) ?? [])
        let stored = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = stored > 0 ? stored : 300
        self.menuBarEnabled = defaults.bool(forKey: Keys.menuBarEnabled)
        self.displayPinnedProvider = defaults.bool(forKey: Keys.displayPinnedProvider)
        self.displayAllowReorder = defaults.bool(forKey: Keys.displayAllowReorder)
        self.displayHideUnconfigured = defaults.bool(forKey: Keys.displayHideUnconfigured)
        self.displayOrder = defaults.stringArray(forKey: Keys.displayOrder) ?? []
        self.displayVisibility = defaults.dictionary(forKey: Keys.displayVisibility) as? [String: Bool] ?? [:]
        self.vaultEntryPaths = SymVaultEntryPaths.load(from: defaults).overrides
    }

    /// The user-facing refresh interval options (minutes).
    static let intervalOptions: [TimeInterval] = [60, 120, 300, 600, 1800, 3600]

    /// Whether a provider is enabled.
    func isEnabled(_ providerID: String) -> Bool {
        enabledProviders.contains(providerID)
    }

    /// Toggles a provider on or off. Disabling never clears the Keychain
    /// credentials — re-enabling stays frictionless.
    func setEnabled(_ providerID: String, _ enabled: Bool) {
        if enabled {
            enabledProviders.insert(providerID)
        } else {
            enabledProviders.remove(providerID)
        }
    }

    // MARK: - Display helpers (issue #361)

    /// Returns the effective display order, merging the user's reordering
    /// with any providers not yet placed.
    func effectiveDisplayOrder(for catalog: [any AIUsageProvider]) -> [String] {
        if displayOrder.isEmpty { return catalog.map(\.id) }
        let seen = Set(displayOrder)
        var result = displayOrder
        for provider in catalog where !seen.contains(provider.id) {
            result.append(provider.id)
        }
        return result
    }

    /// Whether the provider should be visible in lists (respecting visibility
    /// overrides and the hide-unconfigured preference).
    func isVisible(_ providerID: String, isConfigured: Bool) -> Bool {
        if let override = displayVisibility[providerID] {
            return override
        }
        return AIUsageVisibility.isVisible(
            hideUnconfigured: displayHideUnconfigured,
            isEnabled: isEnabled(providerID),
            isConfigured: isConfigured
        )
    }

    // MARK: - SymVault entry paths (issue #376)

    /// The user's chosen entry paths, as the Core value the usage client uses.
    var entryPaths: SymVaultEntryPaths { SymVaultEntryPaths(vaultEntryPaths) }

    /// Points a provider at an existing SymVault entry. An empty value clears
    /// the choice (back to the default); an unusable one is rejected and
    /// leaves the current choice untouched. Returns whether it was accepted.
    @discardableResult
    func setVaultEntryPath(_ raw: String, for providerID: String) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vaultEntryPaths.removeValue(forKey: providerID)
            return true
        }
        guard let path = SymVaultEntryPaths.normalize(raw) else { return false }
        vaultEntryPaths[providerID] = path
        return true
    }

    /// Toggles per-provider visibility override (nil = use default).
    func setVisibility(_ providerID: String, visible: Bool?) {
        if let visible {
            displayVisibility[providerID] = visible
        } else {
            displayVisibility.removeValue(forKey: providerID)
        }
    }
}

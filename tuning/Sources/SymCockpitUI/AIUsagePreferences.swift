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
        didSet {
            if oldValue != enabledProviders {
                undoManager.registerUndo(withTarget: self) { $0.enabledProviders = oldValue }
            }
            enabledRevision += 1
            defaults.set(Array(enabledProviders), forKey: Keys.enabledProviders)
            onUsageSelectionChanged?()
        }
    }
    private(set) var enabledRevision = 0
    var onUsageSelectionChanged: (() -> Void)?

    @Published var claudeHistoryEnabled: Bool {
        didSet {
            guard oldValue != claudeHistoryEnabled else { return }
            enabledRevision += 1
            defaults.set(claudeHistoryEnabled, forKey: Keys.claudeHistoryEnabled)
            onUsageSelectionChanged?()
        }
    }
    @Published var claudeHistoryOnly: Bool {
        didSet {
            guard oldValue != claudeHistoryOnly else { return }
            enabledRevision += 1
            defaults.set(claudeHistoryOnly, forKey: Keys.claudeHistoryOnly)
            onUsageSelectionChanged?()
        }
    }

    @Published var codexHistoryEnabled: Bool {
        didSet {
            guard oldValue != codexHistoryEnabled else { return }
            enabledRevision += 1
            defaults.set(codexHistoryEnabled, forKey: Keys.codexHistoryEnabled)
            onUsageSelectionChanged?()
        }
    }
    @Published var codexHistoryOnly: Bool {
        didSet {
            guard oldValue != codexHistoryOnly else { return }
            enabledRevision += 1
            defaults.set(codexHistoryOnly, forKey: Keys.codexHistoryOnly)
            onUsageSelectionChanged?()
        }
    }

    @Published var grokHistoryEnabled: Bool {
        didSet {
            guard oldValue != grokHistoryEnabled else { return }
            enabledRevision += 1
            defaults.set(grokHistoryEnabled, forKey: Keys.grokHistoryEnabled)
            onUsageSelectionChanged?()
        }
    }

    @Published var opencodeHistoryEnabled: Bool {
        didSet {
            guard oldValue != opencodeHistoryEnabled else { return }
            enabledRevision += 1
            defaults.set(opencodeHistoryEnabled, forKey: Keys.opencodeHistoryEnabled)
            onUsageSelectionChanged?()
        }
    }

    @Published var localSpendPeriod: AIUsageLocalRecordedSpend.Period {
        didSet { defaults.set(localSpendPeriod.rawValue, forKey: Keys.localSpendPeriod) }
    }
    @Published var localSpendMode: AIUsageLocalRecordedSpend.Mode {
        didSet { defaults.set(localSpendMode.rawValue, forKey: Keys.localSpendMode) }
    }

    var consentedHistoryProviders: Set<String> {
        Set([grokHistoryEnabled ? "grok" : nil, opencodeHistoryEnabled ? "opencode" : nil,
             claudeHistoryEnabled ? "claude" : nil, codexHistoryEnabled ? "codex" : nil].compactMap { $0 })
            .intersection(enabledProviders)
    }

    /// Refresh interval in seconds (default 5 minutes).
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    /// Whether the menu bar shows a compact AI usage readout.
    @Published var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: Keys.menuBarEnabled) }
    }

    @Published var localAPIEnabled: Bool {
        didSet { defaults.set(localAPIEnabled, forKey: Keys.localAPIEnabled) }
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
        didSet {
            if oldValue != displayOrder { undoManager.registerUndo(withTarget: self) { $0.displayOrder = oldValue } }
            defaults.set(displayOrder, forKey: Keys.displayOrder)
        }
    }

    /// Visibility overrides per provider ID (`.hidden` or `.shown`).
    @Published var displayVisibility: [String: Bool] {
        didSet {
            if oldValue != displayVisibility { undoManager.registerUndo(withTarget: self) { $0.displayVisibility = oldValue } }
            defaults.set(displayVisibility, forKey: Keys.displayVisibility)
        }
    }

    /// Custom SymVault entry path per provider ID (issue #376). Opaque paths
    /// only — never a secret. Grok/Devin/OpenCode discover local auth without an
    /// explicit entry; other key providers use `symtune/<provider>`.
    @Published private(set) var vaultEntryPaths: [String: String] {
        didSet { defaults.set(vaultEntryPaths, forKey: Keys.vaultEntryPaths) }
    }

    @Published var layout: AIUsageLayout {
        didSet {
            if oldValue != layout { undoManager.registerUndo(withTarget: self) { $0.layout = oldValue } }
            if let data = try? JSONEncoder().encode(layout) {
                defaults.set(data, forKey: Self.layoutKey)
            }
        }
    }
    private static let layoutKey = "com.symaira.symtune.aiUsage.layout.v1"
    let undoManager = UndoManager()

    /// Reset appearance only. Provider consent and credentials are untouched.
    func resetCustomization(providerID: String? = nil) {
        if let providerID {
            let prefix = "\(providerID.utf8.count):\(providerID)"
            var next = layout
            next.pins.removeValue(forKey: providerID)
            next.metricOrder.removeValue(forKey: providerID)
            next.hidden = next.hidden.filter { !$0.hasPrefix(prefix) && $0 != "balance:\(providerID)" }
            next.onDemand = next.onDemand.filter { !$0.hasPrefix(prefix) && $0 != "balance:\(providerID)" }
            next.expanded.remove(providerID)
            layout = next
            displayVisibility.removeValue(forKey: providerID)
        } else {
            layout = AIUsageLayout()
            displayOrder = []
            displayVisibility = [:]
        }
        undoManager.removeAllActions()
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let enabledProviders = "com.symaira.symtune.aiUsage.enabledProviders"
        static let refreshInterval = "com.symaira.symtune.aiUsage.refreshInterval"
        static let menuBarEnabled = "com.symaira.symtune.aiUsage.menuBarEnabled"
        static let codexHistoryEnabled = "com.symaira.symtune.aiUsage.codexHistoryEnabled"
        static let codexHistoryOnly = "com.symaira.symtune.aiUsage.codexHistoryOnly"
        static let claudeHistoryEnabled = "com.symaira.symtune.aiUsage.claudeHistoryEnabled"
        static let claudeHistoryOnly = "com.symaira.symtune.aiUsage.claudeHistoryOnly"
        static let grokHistoryEnabled = "com.symaira.symtune.aiUsage.grokHistoryEnabled"
        static let opencodeHistoryEnabled = "com.symaira.symtune.aiUsage.opencodeHistoryEnabled"
        static let localSpendPeriod = "com.symaira.symtune.aiUsage.localSpendPeriod"
        static let localSpendMode = "com.symaira.symtune.aiUsage.localSpendMode"
        static let localAPIEnabled = "com.symaira.symtune.aiUsage.localAPIEnabled"
        static let displayPinnedProvider = "com.symaira.symtune.aiUsage.displayPinnedProvider"
        static let displayAllowReorder = "com.symaira.symtune.aiUsage.displayAllowReorder"
        static let displayHideUnconfigured = "com.symaira.symtune.aiUsage.displayHideUnconfigured"
        static let displayOrder = "com.symaira.symtune.aiUsage.displayOrder"
        static let displayVisibility = "com.symaira.symtune.aiUsage.displayVisibility"
        static let vaultEntryPaths = SymVaultEntryPaths.defaultsKey
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.layout = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(AIUsageLayout.self, from: $0) } ?? AIUsageLayout()
        self.enabledProviders = Set(defaults.stringArray(forKey: Keys.enabledProviders) ?? [])
        let stored = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = stored > 0 ? stored : 300
        self.menuBarEnabled = defaults.bool(forKey: Keys.menuBarEnabled)
        self.localAPIEnabled = defaults.bool(forKey: Keys.localAPIEnabled)
        self.codexHistoryEnabled = defaults.bool(forKey: Keys.codexHistoryEnabled)
        self.codexHistoryOnly = defaults.bool(forKey: Keys.codexHistoryOnly)
        self.claudeHistoryEnabled = defaults.bool(forKey: Keys.claudeHistoryEnabled)
        self.claudeHistoryOnly = defaults.bool(forKey: Keys.claudeHistoryOnly)
        self.grokHistoryEnabled = defaults.bool(forKey: Keys.grokHistoryEnabled)
        self.opencodeHistoryEnabled = defaults.bool(forKey: Keys.opencodeHistoryEnabled)
        self.localSpendPeriod = AIUsageLocalRecordedSpend.Period(rawValue: defaults.string(forKey: Keys.localSpendPeriod) ?? "") ?? .today
        self.localSpendMode = AIUsageLocalRecordedSpend.Mode(rawValue: defaults.string(forKey: Keys.localSpendMode) ?? "") ?? .cost
        self.displayPinnedProvider = defaults.bool(forKey: Keys.displayPinnedProvider)
        self.displayAllowReorder = defaults.bool(forKey: Keys.displayAllowReorder)
        self.displayHideUnconfigured = defaults.bool(forKey: Keys.displayHideUnconfigured)
        self.displayOrder = defaults.stringArray(forKey: Keys.displayOrder) ?? []
        self.displayVisibility = defaults.dictionary(forKey: Keys.displayVisibility) as? [String: Bool] ?? [:]
        self.vaultEntryPaths = SymVaultEntryPaths.load(from: defaults).overrides
        undoManager.levelsOfUndo = 50
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
        AIUsageLayout.ordered(displayOrder, available: catalog.map(\.id))
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

    /// Select the owned entry only after a successful explicit save.
    func saveCredential(_ value: String, for providerID: String, store: SymVaultCredentialStore) throws {
        try store.save(value, for: providerID)
        if SymVaultEntryPaths.usesLocalDiscovery(for: providerID) {
            setVaultEntryPath(SymVaultCredentialStore.defaultEntryPath(for: providerID), for: providerID)
        }
    }

    func deleteCredential(for providerID: String, store: SymVaultCredentialStore) -> Bool {
        guard store.delete(for: providerID) else { return false }
        if SymVaultEntryPaths.usesLocalDiscovery(for: providerID) {
            setVaultEntryPath("", for: providerID)
        }
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

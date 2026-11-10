import Foundation

/// The persisted "which providers did the user enable" set that the GUI writes.
///
/// The GUI stores it in its own `UserDefaults` domain (bundle ID
/// `com.symaira.cockpit`; the standalone menu-bar app uses `com.symaira.tune`).
/// A separate process such as `symcockpit ai-usage serve` must read that
/// domain explicitly, otherwise it would see its own, empty preferences.
/// Absent or unreadable preferences mean "nothing enabled": callers fail closed.
public enum AIUsageEnabledProviders {
    /// Grandfathered preference key (see AGENTS.md); do not rename.
    public static let defaultsKey = "com.symaira.symtune.aiUsage.enabledProviders"

    /// GUI preference domains, most specific first.
    public static let defaultsDomains = ["com.symaira.cockpit", "com.symaira.tune"]

    /// The enabled set of the first store that holds the key; empty if none does.
    public static func load(from stores: [UserDefaults]) -> Set<String> {
        for store in stores {
            if let stored = store.stringArray(forKey: defaultsKey) { return Set(stored) }
        }
        return []
    }

    /// Reads the GUI's persisted selection from its preference domains.
    /// Fresh stores per call, so a running server sees GUI changes.
    public static func loadPersisted(domains: [String] = defaultsDomains) -> Set<String> {
        load(from: domains.compactMap { UserDefaults(suiteName: $0) })
    }
}

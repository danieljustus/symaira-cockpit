// PB-2026-09-09 §4/§8: reviewed command ownership for the transitional
// direct-command spelling. Keep this table authoritative: the dispatcher,
// documentation, and acceptance tests must agree before any prefix retirement.
enum CockpitCommandMap {
    /// Tune commands safe to expose at the root because neither retained
    /// family owns the same command name.
    static let directTuneCommands: [String] = [
        "sensors", "battery", "displays", "metrics", "ai-usage",
        "processes", "top",
        "status", "awake", "brightness", "extbright", "dim", "warmth",
        "restore", "profile", "fan", "battery-limit",
    ]

    /// Tune commands retained behind `tune` because Operate and/or Scope own
    /// the same spelling at the unified dispatcher boundary.
    static let collidingTuneCommands: [String] = [
        "doctor", "permissions", "serve", "history",
    ]

    /// Existing family spellings and version aliases. These are compatibility
    /// surfaces, not new product names, and remain until a separately
    /// authorized release supplies a tested migration and rollback.
    static let legacyFamilyCommands: [String] = ["tune", "operate", "scope"]
    static let rootVersionAliases: [String] = ["version", "--version", "-V"]
}

let tuneDirectAliases = Set(CockpitCommandMap.directTuneCommands)

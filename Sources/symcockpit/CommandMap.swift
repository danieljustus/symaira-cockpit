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

    /// Tune commands retained behind `tune` for explicit command discovery.
    static let collidingTuneCommands: [String] = [
        "doctor", "permissions", "serve", "history",
    ]

    /// The tune family spelling and version aliases.
    static let legacyFamilyCommands: [String] = ["tune"]
    static let rootVersionAliases: [String] = ["version", "--version", "-V"]
}

let tuneDirectAliases = Set(CockpitCommandMap.directTuneCommands)

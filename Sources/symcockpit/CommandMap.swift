// PB-2026-09-09 §4/§8: reviewed command ownership. Keep this table
// authoritative: the dispatcher, documentation, and acceptance tests must
// agree. The legacy `tune` prefix was removed in v0.12.
enum CockpitCommandMap {
    /// Tune commands exposed at the root. Former collisions with Operate and
    /// Scope were resolved when those families moved to Brain.
    static let directTuneCommands: [String] = [
        "sensors", "battery", "displays", "metrics", "ai-usage",
        "processes", "top",
        "status", "awake", "brightness", "extbright", "dim", "warmth",
        "restore", "profile", "fan", "battery-limit",
        "doctor", "permissions", "serve", "history",
    ]

    /// The removed tune family spelling (answers with a migration hint) and
    /// the version aliases.
    static let legacyFamilyCommands: [String] = ["tune"]
    static let rootVersionAliases: [String] = ["version", "--version", "-V"]
}

let tuneDirectAliases = Set(CockpitCommandMap.directTuneCommands)

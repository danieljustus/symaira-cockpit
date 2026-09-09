// PB-2026-09-09 (docs/product-boundaries.md §4, §8): the `tune` family name
// is redundant — hardware/system tuning is what symcockpit *is* — so its
// commands are also reachable directly at the root, without the `tune`
// prefix. `symcockpit tune <cmd>` keeps working unchanged: this is an
// addition, not a replacement, pending a documented deprecation window
// before the prefix itself is ever retired.
//
// Excluded by a real name collision with `operate` and/or `scope` (checked
// against both command surfaces on 2026-09-09 — see
// symaira-cockpit#259):
//   doctor      — also an `operate` command
//   permissions — also an `operate` command
//   serve       — also an `operate` AND a `scope` command
//   history     — also an `operate` command
// These four stay reachable only via `symcockpit tune <cmd>`; aliasing them
// at the root would silently pick one family's meaning over the others'.
let tuneDirectAliases: Set<String> = [
    "sensors", "battery", "displays", "metrics", "ai-usage",
    "processes", "top",
    "status", "awake", "brightness", "extbright", "dim", "warmth",
    "restore", "profile", "fan", "battery-limit",
]

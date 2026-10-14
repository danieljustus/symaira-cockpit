# Tune/SymTune naming inventory

Status: reviewed inventory required by PB-2026-09-09 §4 before any internal
renaming. Each identifier has a verdict: **grandfathered** (never rename, or
only via its own tested migration with rollback) or **migratable** (safe to
rename in one mechanical sweep).

Deprecation window: the `symcockpit tune …` prefix is supported through
Cockpit v0.9 and prints a deprecation warning
(`Sources/symcockpit/main.swift`). Removing the prefix entirely is gated on
that window ending and is intentionally not part of the v0.8.2 work.

## Grandfathered — do not rename here

| Identifier | Where | Why |
|---|---|---|
| `com.symaira.symtune` (Keychain service, UserDefaults namespace) | `tune/Sources/SymTuneCore/ReadoutSurface.swift:26-38`, `BrightnessKeys.swift:25-29`, `SymVaultCredentialStore.swift:87` | Renaming orphans stored credentials and preferences; AGENTS.md marks it grandfathered. |
| `com.symaira.symtune-helper` (privileged helper identity + SMAppService plist) | `tune/Sources/SymTuneCore/SMCHelperProtocol.swift:14-15` | Renaming breaks helper authorization. |
| XDG data paths `~/.config/symtune/`, `~/.cache/symtune/`, `~/.local/share/symtune/` | `tune/Sources/SymTuneCore/Config.swift:31-35` (`ConfigPaths`) | Live user configuration and state; a rename needs a tested migration. |
| `SYMTUNE_*` environment prefix | `tune/Sources/SymTuneCore/Config.swift:41,292-301`, `UpdateChecker.swift:88`, `tune/Sources/SymTuneCLI/SymTuneMain.swift:611` | Documented external interface; changing it requires a dual-read support window. |
| `symvault://symtune/…` credential reference prefix | `tune/Sources/SymTuneCore/SymVaultCredentialStore.swift:87`, tests in `tune/Tests/SymTuneCoreTests/SymVaultCredentialStoreTests.swift` | Addresses already-stored credentials; renaming orphans them. Same class as the Keychain service. |
| Homebrew formula/cask names (`symcockpit`) | `Formula/symcockpit.rb`, `Casks/symcockpit.rb` in `danieljustus/homebrew-tap` | Already Cockpit naming; no action. |

## Resolved in #338 — data contracts

- Doctor/capabilities JSON `tool` field: renamed `symtune` → `symcockpit`
  (`tune/Sources/SymTuneCore/TuneController.swift`). It is the reporting
  product's self-declared identity, so it follows the product name; the
  `symcockpit version --json` schema keeps its `families` key, now empty.

## Migratable — one mechanical sweep

| Identifier | Where | Notes |
|---|---|---|
| Swift targets/modules `SymTuneCore`, `SymTuneCLI`, `SymTuneMCP`, `SymTuneUI`, `SymTuneApp` | `tune/Package.swift`, `Package.swift`, `tune/project.yml` | Internal only; ripples through imports, `Makefile` (`PACKAGES`) and both CI matrices. |
| `tune/` package directory | repo root | Pure path rename; update `Package.swift`, `Makefile`, `.github/workflows/ci.yml`, docs. |
| Package-local `symtune` executable target | `tune/Package.swift` | Compatibility entry point, not a shipped CLI product. |
| `tune` family line in `symcockpit version` and the `symcockpit X — tune Y` one-liner | `Sources/symcockpit/main.swift:82,110` | User-facing; covered by #338. |
| MCP server identity `MCPServer(name: "symtune", …)` | `tune/Sources/SymTuneMCP/TuneMCPServer.swift:67` | Agent-facing; covered by #338. |
| Help/usage wording ("tune command tree", `symtune` banner) | `Sources/symcockpit/main.swift`, `tune/Sources/SymTuneCLI/SymTuneMain.swift:6,97` | Covered by #338. |
| README/docs describing a tune family | `README.md`, `tune/README.md`, `tune/docs/` | Follow the code rename; historical notes stay. |

## Execution order

1. #338 — user-facing CLI/MCP naming (small, independent).
2. #339 — internal module + directory rename (large mechanical sweep; only
   after #338 so user-facing and internal renames do not interleave).

Unblocks: #338, #339. After v0.9 ships, a separate issue covers removing the
`tune` command prefix and the package-local `symtune` executable.

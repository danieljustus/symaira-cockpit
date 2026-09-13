# Agent Instructions — symaira-cockpit

## Current product contract

[PB-2026-09-09](docs/product-boundaries.md) defines Cockpit as the
macOS hardware/system-tuning product under the sole name Symaira Cockpit
(`symcockpit`). **Cutover 2026-09-13:** Operate and Scope moved to Symaira
Brain as independently optional modules and have been removed from this repo.
`SymOperate` and `SymScope` sources, user interfaces and MCP servers belong to
Brain; `symcockpit operate` and `symcockpit scope` print a migration hint and
exit 4. Do not reintroduce them here or move hardware control into Brain.

**This machine.** One binary, `symcockpit`, owns thermals/power/display through
the `tune` command tree and its direct aliases. It ships one Tune MCP server,
a menu-bar HUD and a tuning GUI. macOS-only, Swift 6, public Apache-2.0.

This repo is the result of merging the archived `symaira-tune`,
`symaira-operate` and `symaira-scope` repositories (repo consolidation step 8,
2026-08-23). The latter two families moved on to Brain in the 2026-09-13
cutover; their old Homebrew formulae/casks remain only as compatibility
history. No release is implied by this source cutover.

## Layout

| Path | Role | Language |
| :--- | :--- | :--- |
| `Sources/symcockpit/` | tune-only dispatcher and version report | Swift 6 |
| `Sources/SymCockpitApp/` | tune-only menu-bar and window GUI | Swift 6 (SwiftUI/AppKit) |
| `tune/` | thermals, power, display and brightness | Swift 6 (AppKit/IOKit) |
| `history/` | canonical history store, replay codec, secret redaction and bounded subprocess runner | Swift 6 |

`SymTuneCLI` is a library target consumed by both Tune's own executable target
and the root dispatcher, so Tune stays independently buildable while
`symcockpit` remains the released CLI surface.

`history/` is not a product family: it has no CLI or MCP server. It is a plain
SPM package that Tune depends on by path. It holds the live privacy boundary
for persisted data: `SecretRedactor` sits at the output boundary.
`ReplayCodec` has no production replay caller. The package is built and tested
alongside Tune (`PACKAGES` in the `Makefile`, both CI matrices).

## Build & Test

```bash
make build                 # swift build in Tune and history
make test                  # swift test in Tune and history
make build-tune            # a single package (also test-tune / test-history)
swift build && swift test  # root dispatcher and GUI integration tests
```

- The full Xcode toolchain is required for app targets and tests;
  CommandLineTools alone fails on `actool`. The Makefile resolves a full local
  Xcode automatically, or set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- CI (`.github/workflows/ci.yml`) runs Tune, history and root `swift build` +
  `swift test` on `macos-latest`.
- The GUI is assembled by `make build-app` (`scripts/build-app.sh`): SwiftPM
  builds `SymCockpitApp` and the script wraps it in
  `build/app/Symaira Cockpit.app`. There is deliberately **no** Xcode project
  for it — the dependency graph is declared once in `Package.swift`.
  `make smoke-app` checks the bundle; `make run-app` launches it.
  Pass `CODE_SIGN_IDENTITY` (any code-signing certificate, self-signed is fine)
  when working on the GUI: macOS keys TCC grants and Keychain "always allow"
  decisions to the signature, so ad-hoc builds re-ask after every rebuild.

## Release

Tag `v*` triggers `.github/workflows/release.yml`: it builds a universal
binary (`--arch arm64 --arch x86_64`), packs a tarball plus checksums, and
publishes the release. A guard fails the run when the tag and
`CockpitVersion.current` disagree — bump the version in the same commit that
carries the tag.

Two more jobs follow the CLI one: `release-macos-app` deep-signs, notarizes
(fail-closed) and uploads `Symaira-Cockpit-*-macos.dmg` plus the GUI `.zip`;
`bump-homebrew` updates `Formula/symcockpit.rb` and `Casks/symcockpit.rb` in
`danieljustus/homebrew-tap` once every artifact is on the release. Their
secrets live in the repo environment `release`.

`symcockpit version` prints the dispatcher and Tune versions. The retired
families are not version components.

## Conventions

### Naming and compatibility

- The GUI is displayed and shipped as `Symaira Cockpit.app`; the Swift target
  remains `SymCockpitApp` for project continuity.
- `com.symaira.symtune` (Keychain service/UserDefaults namespace) and
  `com.symaira.symtune-helper` (privileged helper identity) are grandfathered
  identifiers. Do not rename them: doing so would orphan stored credentials and
  preferences or break helper authorization.
- **One shipped CLI binary.** `symcockpit` is the only Cockpit command-line
  product. Do not reintroduce standalone distribution for `symtune`,
  `symoperate` or `symscope`; Brain owns the latter two module binaries.
  `SymCockpitApp` is a different artifact class (an `.app`, distributed as a
  cask), not a second CLI.
- **No credential I/O at construction — and no plaintext at all.** The
  AI-usage provider catalog is built on every launch and every CLI invocation,
  so an eager credential read would pop a system dialog for an entry the user
  may never use. `SymBrainUsageProvider` carries metadata only.
  `SymVaultCredentialStore.reference(for:)` builds an opaque `symvault://` URI;
  that reference — never a secret — goes into the child environment for
  `symbrain usage`, which resolves it itself. Tests protect this boundary.
- **The GUI owns no logic.** It reads `SymTuneCore` and embeds `SymTuneUI`'s
  panel rather than reimplementing it, so the window cannot report something
  `symcockpit` would contradict.
- **One panel, two chromes.** `MainStatusView` renders the same cards for the
  popover and cockpit window; `TunePanelChrome` decides only the frame. Do not
  fork the panel for the window.
- **`SymTuneUI` is shared.** Tune's menu-bar UI lives in
  `tune/Sources/SymTuneUI/`, consumed by both `SymTuneApp` and the cockpit GUI.
  `tune/project.yml` mirrors that split for XcodeGen — keep both in sync when
  adding files.
- **Brightness keys are opt-in and default to macOS.**
  `BrightnessKeyHandling` / `BrightnessKeyStep` (SymTuneCore) hold the
  preference and step arithmetic; `BrightnessKeyController` (SymTuneUI) owns
  the `CGEventTap` and `BrightnessHUDPanel` the stand-in HUD. It runs only when
  the host offers it and the user picks it. Preserve pass-through for
  non-brightness keys, re-enable disabled taps, honour secure event input, and
  tear the tap down on disable and `deinit`.
- **The readout has one surface at a time.** `ReadoutSurface` is the choice
  (menu bar or notch). `StatusBarController.syncReadoutSurface()` is the only
  place that chooses the active surface; an unavailable notch preference must
  leave the menu-bar status item visible.
- **The HUD is opt-in and isolated.** Geometry and presentation rules live in
  SymTuneCore; `HUDDockController` / `HUDDockView` / `NotchHUDView` render from
  the shared `TuneViewModel`. Keep the HUD removable and free of business rules.
- **The HUD opens in three steps, and the shoulders are a hard budget.**
  `HUDPresentation` is ordered (`collapsed < peek < expanded`); shoulders never
  render past `.peek` because card-width content there becomes a clipped fragment.
- Environment prefix: `SYMTUNE_*`. Tune uses its documented XDG paths.
- Exit codes: `0` ok · `1` error · `2` usage/config · `3` permission ·
  `4` unsupported/not-implemented.
- **Zero stdio pollution** in `tune serve`: stdout carries JSON-RPC only;
  everything else goes to stderr.
- Public Apache-2.0 — no billing, tenant or cloud code here. There is no Pro
  edition; see `tune/docs/commercial-boundary.md`.
- Tune's SMC writes (fans, charge limits) need `sudo`. The GUI elevates through
  `osascript`'s `do shell script … with administrator privileges`. Resolve the
  elevated CLI only with `PrivilegedExecutableResolver`, which requires the
  binary and every parent directory to be root-owned and not group- or
  other-writable. Do not widen it to the unprivileged fallback search: it
  includes `~/.symaira/bin` and Homebrew prefixes, which are user-writable on a
  normal Mac, and a binary planted there could be authenticated into root by the
  user's own password prompt. GUI fan control therefore requires a root-owned
  install (e.g. `/usr/local/bin`); the README documents the trade-off.
- Anything an elevated child writes must be told where to write. It runs under
  `osascript`, which sets no `SUDO_*` variables, so pass `--data-dir` (as the
  fan governor passes `--state`) and restore ownership from the directory owner
  via `StateFilePermissions`, never from `SUDO_UID` alone.

Cross-repo conventions live in the workspace `AGENTS.md` and `ECOSYSTEM.md`,
which are not part of this repository.

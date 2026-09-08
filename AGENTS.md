# Agent Instructions — symaira-cockpit

**This machine.** One binary, `symcockpit`, with three families of commands:
thermals/power (`tune`), macOS GUI automation (`operate`), and port/container/MCP
inventory (`scope`). CLI **and** MCP server per family. macOS-only, Swift 6,
public Apache-2.0.

This repo is the result of merging the archived `symaira-tune`,
`symaira-operate` and `symaira-scope` repositories (repo consolidation step 8,
2026-08-23). Their Homebrew formulae/casks are deprecated and point here.

## Layout

| Path | Family | Language |
| :--- | :--- | :--- |
| `Sources/symcockpit/` | dispatcher — routes `tune\|operate\|scope` | Swift 6 |
| `Sources/SymCockpitApp/` | the GUI — menu bar + cockpit window | Swift 6 (SwiftUI/AppKit) |
| `tune/` | thermals, power, display, brightness | Swift 6 (AppKit/IOKit) |
| `operate/` | screenshots, AX tree, input, apps/windows | Swift 6 (AppKit/AX/ScreenCaptureKit) |
| `scope/` | ports, containers, MCP servers, health | Swift 6 |
| `history/` | shared library: canonical history store, replay codec, secret redaction, bounded subprocess runner | Swift 6 |

Each family is its own SPM package with its own `Package.swift` and its own
`AGENTS.md`. The CLI logic lives in a library target (`SymTuneCLI`,
`SymOperateCLI`, `SymScopeCLI`) consumed by **both** the package's own
executable target and the root dispatcher — so a family stays independently
buildable while only `symcockpit` is released.

`history/` is not a family: it has no CLI, no MCP server and no `AGENTS.md`
of its own. It is a plain SPM package that `tune/` and `operate/` depend on
by path. It holds the live privacy boundary for everything the tool persists:
`SecretRedactor` sits at the output boundary. `ReplayCodec` will decide which
recorded actions are safe to replay once a replay surface exists; it currently
has no production caller. The package is built and tested with the other
packages (`PACKAGES` in the `Makefile`, both matrices in
`.github/workflows/ci.yml`).

## Build & Test

```bash
make build                 # swift build in every package
make test                  # swift test in every package
make build-tune            # a single package (also test-tune, build-operate, …)
swift build && swift test  # the root dispatcher only
```

- Xcode(-beta) is required for the app targets and for tests:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
  CommandLineTools alone fails on `actool`.
- CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on
  `macos-latest`.
- The GUI is assembled by `make build-app` (`scripts/build-app.sh`): SwiftPM
  builds the `SymCockpitApp` product and the script wraps it in
  `build/app/Symaira Cockpit.app`. There is deliberately **no** Xcode project
  for it — the dependency graph is declared once, in `Package.swift`.
  `make smoke-app` checks the assembled bundle; `make run-app` launches it.
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
danieljustus/homebrew-tap once every artifact is on the release. Their secrets
live in the repo environment `release`.

`symcockpit version` prints the dispatcher version plus each family's version.

## Conventions

### Naming and compatibility

- The Tune app is displayed and shipped as `Symaira Tune.app`; the Xcode target and scheme remain `SymairaTune` for project continuity.
- `com.symaira.symtune` (Keychain service/UserDefaults namespace) and `com.symaira.symtune-helper` (privileged helper identity) are grandfathered identifiers. Do not rename them: doing so would orphan stored credentials and preferences or break helper authorization.

- **One shipped CLI binary.** `symcockpit` is the only command-line product.
  Do not reintroduce standalone distribution for `symtune`/`symoperate`/
  `symscope` — their formulae are deprecated on purpose. The one other root
  product is `SymCockpitApp`, the GUI; it is a different artifact class (an
  `.app`, distributed as a cask), not a second CLI.
- **No credential I/O at construction — and no plaintext at all.** The
  AI-usage provider catalog is built on every launch and every CLI
  invocation, so an eager credential read would pop a system dialog for an
  entry the user may never use. `SymBrainUsageProvider` therefore carries
  metadata only. Beyond that, cockpit does not resolve provider secrets at
  any point: `SymVaultCredentialStore.reference(for:)` builds an opaque
  `symvault://` URI, and that reference — never a secret — is what goes into
  the child environment for `symbrain usage`, which resolves it itself. Two
  tests hold the line:
  `SymVaultCredentialStoreTests.testReferenceUsesSymVaultWithoutReadingASecret`
  and
  `AIUsageServiceTests.testInvokesExactPublishedCommandAndPassesSymVaultReferenceToEnvironment`.
- **The GUI owns no logic.** Every section reads the same core services the
  CLI does (`SymTuneCore`, `SymScopeCore`, `SymOperateCore`), and the Tune
  section embeds `SymTuneUI`'s panel rather than reimplementing it, so the
  window can never report something `symcockpit` would contradict.
- **One panel, two chromes.** `MainStatusView` renders the same cards for the
  popover and for the cockpit window; `TunePanelChrome` decides only the frame
  around them (fixed width + header + footer, or fill the host). Do not fork
  the panel for the window — that is exactly the drift the embedding exists to
  prevent.
- **`SymTuneUI` is shared.** Tune's menu-bar UI lives in the `SymTuneUI`
  library (`tune/Sources/SymTuneUI/`), consumed by both `SymTuneApp` and the
  cockpit GUI. `tune/project.yml` mirrors that split for the XcodeGen build —
  keep both in sync when adding files.
- **The readout has one surface at a time.** `ReadoutSurface` (SymTuneCore)
  is the choice — menu bar or notch — with the migration off the #224 boolean
  and the availability fallback as pure, unit-tested functions;
  `ReadoutSurfacePreferences` (SymTuneUI) stores it under the grandfathered
  `com.symaira.symtune` keys. `StatusBarController.syncReadoutSurface()` is the
  only place that decides which surface runs, and it must keep resolving the
  stored choice through `ReadoutSurfaceDefaults.effective` — a `.notch`
  preference on a display without a cutout has to leave the status item
  visible, or the app has no surface and no way back to its own preferences.
- **The notch HUD is opt-in and isolated.** `NotchLayout` (SymTuneCore) holds
  the geometry and is unit-tested; `NotchHUDController`/`NotchHUDView`
  (SymTuneUI) hold the panel and its rendering. It runs only when the host sets
  `StatusBarController.isNotchHUDOffered` (SymCockpitApp does, SymTuneApp does
  not) *and* the user picks the notch surface, and it renders from the shared
  `TuneViewModel` — no second metrics pipeline. Keep it removable: it draws
  over the menu bar, which is the part of macOS most likely to change.
- **Env prefixes stay per family**: `SYMTUNE_*`, `SYMOPERATE_*`, `SYMSCOPE_*`.
- XDG paths: `~/.config/<tool>/`, `~/.cache/<tool>/`, `~/.local/share/<tool>/`.
- Exit codes: `0` ok · `1` error · `2` usage/config · `3` permission ·
  `4` unsupported/not-implemented.
- **Zero stdio pollution** in every `serve` (MCP) path: stdout carries JSON-RPC
  only, everything else goes to stderr.
- Public Apache-2.0 — no billing, tenant, or cloud code here. There is no Pro
  edition; see `tune/docs/commercial-boundary.md`.
- `operate` needs Accessibility and Screen Recording permissions; `tune`'s SMC
  writes (fans, charge limits) need `sudo`. TCC grants are per-binary, so the
  GUI bundle needs its own — the Operate section asks for them.
- The GUI elevates through `osascript`'s `do shell script … with administrator
  privileges`. Resolve the binary for that path only with
  `BoundedProcessRunner.resolvePrivilegedExecutablePath`, which requires the
  binary and every parent directory to be root-owned and not group- or
  other-writable. Do not widen it to the unprivileged fallback search: it
  includes `~/.symaira/bin` and the Homebrew prefixes, which are user-writable
  on a normal Mac, and a binary planted there would be authenticated into root
  by the user's own password prompt. This means GUI fan control requires a
  root-owned install (e.g. `/usr/local/bin`); the README documents the
  trade-off. Unprivileged `BoundedProcessRunner.run` resolution for `symbrain`
  and `symvault` deliberately keeps the wide search.
- Anything the elevated child writes must be told where to write. It runs under
  `osascript`, which sets no `SUDO_*` variables, so pass `--data-dir` (as the
  fan governor already passes `--state`) and restore ownership from the
  directory's owner via `StateFilePermissions`, never from `SUDO_UID` alone.

Cross-repo conventions live in the workspace `AGENTS.md` and `ECOSYSTEM.md`,
which are not part of this repository.

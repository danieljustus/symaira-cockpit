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

Each family is its own SPM package with its own `Package.swift` and its own
`AGENTS.md`. The CLI logic lives in a library target (`SymTuneCLI`,
`SymOperateCLI`, `SymScopeCLI`) consumed by **both** the package's own
executable target and the root dispatcher — so a family stays independently
buildable while only `symcockpit` is released.

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
(fail-closed) and uploads `Symaira-Cockpit-*.dmg`/`.zip` of the GUI;
`bump-homebrew` updates `Formula/symcockpit.rb` and `Casks/symcockpit.rb` in
danieljustus/homebrew-tap once every artifact is on the release. Their secrets
live in the repo environment `release`.

`symcockpit version` prints the dispatcher version plus each family's version.

## Conventions

- **One shipped CLI binary.** `symcockpit` is the only command-line product.
  Do not reintroduce standalone distribution for `symtune`/`symoperate`/
  `symscope` — their formulae are deprecated on purpose. The one other root
  product is `SymCockpitApp`, the GUI; it is a different artifact class (an
  `.app`, distributed as a cask), not a second CLI.
- **No credential I/O at construction.** AI-usage providers resolve their
  Keychain/environment credentials lazily (`CredentialCache`), because the
  catalog is built on every launch and every CLI invocation — an eager read
  pops a system dialog for an entry the user may never use. New providers must
  follow suit; `CredentialLazinessTests` guards it.
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

Cross-repo conventions live in the workspace `AGENTS.md` and `ECOSYSTEM.md`,
which are not part of this repository.

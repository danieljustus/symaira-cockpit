# Roadmap

Source of truth for what's built vs planned. Capability IDs match `doctor`.

## v0.1 — core reads + writes (shipped)

- [x] SPM package, three targets, CI, docs, safety policy.
- [x] `sensors.thermalPressure` — coarse thermal level from `ProcessInfo`.
- [x] `sensors.smc` — AppleSMC IOKit bridge for die temps + fan RPM (unprivileged).
- [x] `battery.read` — `AppleSmartBattery` health (charge %, cycles, capacity).
- [x] `display.edr.read` — per-display EDR headroom.
- [x] `display.brightness.set` — built-in brightness get/set.
- [x] `display.brightness.extended.set` — EDR/extended brightness, clamped 1.0–1.6.
- [x] `display.dim.set` — sub-minimum software dim overlay, clamped ≥ 0.15.
- [x] `display.warmth.set` — color temperature warmth (gamma) beyond Night Shift.
- [x] `power.keepAwake` — IOKit power assertion (CLI `awake`, MCP `keep_awake`).
- [x] Profiles (save/load/list/delete) and simple rule engine.
- [x] Restore-on-exit for all applied display overrides.
- [x] Wire `config.toml` (`SYMTUNE_*` overrides) via `ConfigPaths`.
- [x] Update checker (GitHub releases).
- [x] MCP server over stdio.

## v0.2 — standalone app / menu-bar target (shipped)

`SymairaTune.app` ships as a standalone, notarized macOS menu-bar app beside
the CLI. It is not a Hub-only component. The XcodeGen project and SwiftUI/AppKit
sources live under `Sources/SymTuneApp/` and `project.yml`; the release workflow
packages both artifacts into the DMG and publishes the matching Homebrew cask.
See [manual app verification](manual-app-verification.md).

- [x] XcodeGen project config (`project.yml`) and SwiftUI menu-bar app sources
- [x] CI build job for the app target with Swift 6 compilation and bundle smoke checks
- [x] Decide distribution: standalone DMG
- [x] Release workflow builds a DMG containing `SymairaTune.app` and `symtune`
- [x] Release workflow signs/notarizes the app when Developer ID and Apple credentials are configured
- [x] Homebrew cask generation installs the app bundle and links the CLI
- [x] Documented real-host end-to-end verification checklist

## v0.3 — SMC writes in the open core (shipped)

All previously planned "Pro" hardware-tuning features are now part of the open
core. They require the process to run as root because they write to the Apple SMC.

- [x] `fan.control` — fixed RPM via manual SMC mode, clamped fraction, firmware
      floor preserved, restore-on-exit.
- [x] `battery.chargeLimit` — inhibit charging via Apple Silicon (`CHTE`/`CH0B`) or
      Intel (`CHLC`) SMC keys, restore-on-exit, AC-power guardrail.
- [x] New CLI commands: `fan auto`, `battery-limit clear`.
- [x] New MCP tools: `clear_charge_limit`.
- [x] Remove Core/Pro split from docs and capability model.
- [x] Safety policy additions: `fanSpeedFloor`, thermal emergency threshold,
      AC adapter check for charge limits.

## v0.3.1 — Update checking via appkit (shipped)

- [x] Update checking via `SymairaUpdateCheck` from `symaira-appkit`: non-blocking
      GitHub release check with skip-version persistence in the menu-bar app.
      Shows a subtle update card with Download/Skip buttons (`#173`).

## v0.4.0 — Keep-awake sessions + CI split (shipped)

- [x] Keep-awake sessions with timer-based expiry, duration presets, display-sleep toggle and remaining-time display (`#178`).
- [x] Fan Control card gated on fan availability (`#176`, `#177`).

## v0.5.0 — System metrics + live menu bar (shipped)

- [x] System metrics service for CPU, memory, disk, and network utilization (`#195`, `#201`).
- [x] CLI `symtune metrics` and MCP `get_system_metrics` tool (`#196`, `#203`).
- [x] Preferences surface for metric selection, ordering, refresh interval and units (`#199`, `#204`).
- [x] Live menu bar metric readout with monospaced digits and update-badge coexistence (`#197`, `#205`).
- [x] Rolling metric history with sparkline trends in the popover (`#200`, `#206`).
- [x] Dim slider amount ↔ multiplier conversion fix (`#175`).
- [x] CI workflow split: fast PR gate on PRs, full suite on main + weekly schedule. CodeQL reduced to weekly.

## v0.8.0 — Design system alignment (current)

- [x] Menu-bar app migrated onto the shared `SymairaTheme` design system from `symaira-appkit`: type scale (`symairaText` roles), color tokens, spacing/radius tokens, shared text field style (`#226`).
- [x] AI-usage fundamentals: `AIUsageSnapshot`/`AIUsageProvider`/`AIUsageService` in the core, OpenRouter provider (Keychain API key, credits API), CLI `symtune ai-usage [--json]` and MCP `get_ai_usage` (`#242`, `#243`, `#254`).

## v0.9.2 (in progress) — brightness correctness, process insight, popover clarity

- [x] `display.brightness.extended.set` **rewritten to actually work**: a 1×1
      EDR trigger layer that is genuinely rendered and presented, plus a
      gamma-table boost clamped to the headroom the display grants. The previous
      implementation presented no drawable and set a non-existent `EDRHeadroom`
      KVC key, so above-normal positions did nothing while the full-screen layer
      still changed how the panel rendered at neutral.
- [x] One owner for the display gamma table (`DisplayGammaController`): warmth
      and extended brightness compose onto the display's *captured* calibration
      ramp instead of overwriting each other, and neutral restores ColorSync.
- [x] `processes.read` — per-process CPU/memory via libproc, as CLI
      `symtune processes`, MCP `get_top_processes`, and an expandable
      Top Processes popover card that samples only while visible.
- [x] Popover: live CPU/memory/thermal strip, two labelled groups, and
      per-value invalidation so a metrics tick no longer re-renders the panel.

## v0.7.0 — Configurable popover

- [x] Configurable popover cards: choose which cards are visible (system status, metric history, displays, display controls, keep-awake, fan control) in the preferences view; persisted in `config.toml` under `[popover] cards` (`#218`).
- [x] SMC availability reporting fix: capability checks report the truth per host, and the status popover no longer overflows (`#217`).
- [x] Status panel perf: stop wholesale re-rendering on every interaction; EDR overlay crash fix (`#209`).
- [x] Test/coverage hardening: config-load test isolation, SMC transport + param-block tests, EDR overlay routing tests, app metric-formatting logic extracted to the core and covered (`#220`, `#221`, `#222`, `#223`).

## v0.6.0 — Auto-update on launch

- [x] Auto-update check on app launch, gated by a settings toggle (`#202`, `#208`).
- [x] In-app install button (`UpdateApplier.applyBundle()`) with download progress and error handling; falls back to the manual download link when no release assets are available (`#202`, `#208`).

## Future / cross-cutting

- [ ] Optional privileged `symtune-helper` daemon via `SMAppService` so users do
      not need to run the whole CLI as root. The helper remains Apache-2.0 in
      this repo.
      Blocking acceptance criteria — the helper must not ship without peer
      validation (`#236`):
      - client authentication per `SMCHelperProtocol`: a code-signing
        requirement pinned to the `symtune` Developer ID team and bundle
        identifier, set on both directions of the `NSXPCConnection`;
      - peer validation via the connection's audit token
        (`SecCodeCopyGuestWithAttributes`), never a PID claimed by the peer;
      - rejection of peers carrying hardened-runtime escape entitlements
        (`allow-dyld-environment-variables`, `disable-library-validation`,
        `allow-unsigned-executable-memory`, `allow-jit`) and a `SecCodeStatus`
        of `valid`, `hard`, `kill`, `libraryValidation`, and `runtime`.
- [ ] DDC/CI external-monitor brightness (IOKit I2C) — evaluate helper vs direct.
- [ ] Tighten to Swift 6 strict concurrency (currently Swift 5 language mode;
      main friction is AppKit MainActor isolation in `DisplayService`).
- [ ] GoReleaser-equivalent release flow: notarized DMG + Homebrew cask in
      `../homebrew-tap` (mirror `symaira-terminal`).
- [ ] Hardware-matrix notes: Apple Silicon vs Intel SMC keys, fanless MacBook Air.

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Extended brightness now actually works.** The old EDR overlay created a
  full-screen `CAMetalLayer` at `opacity = 0`, never presented a drawable, and
  set a non-existent `EDRHeadroom` key via KVC — so everything above "Normal"
  changed nothing, while the full-screen layer was still enough to alter how the
  panel rendered, which is why the screen looked brighter than normal even at
  the neutral position. Replaced by a 1×1 EDR trigger layer that is genuinely
  rendered and presented (`rgba16Float` + extended-linear colour space) plus a
  gamma-table boost, clamped to the headroom the display actually grants.
- Colour warmth no longer replaces the display's gamma table with a freshly
  built linear ramp. It threw away the panel's own calibration curve, so even
  neutral warmth visibly changed the screen and it silently wiped any active
  brightness boost. Warmth and boost are now composed onto the captured base
  ramp by a single owner (`DisplayGammaController`).
- "Normal" is now genuinely neutral: at the centre position no windows are left
  on screen and the gamma table is handed back to ColorSync. The dim overlay no
  longer creates fully transparent screen-sized windows for "no dim", and
  restore-on-exit no longer re-applies the previously *observed* EDR headroom as
  a boost.
- Display overrides are re-asserted after wake, where macOS resets the gamma
  table and silently drops an active boost or warmth shift.

### Added
- **Top Processes**: which processes are using the most CPU or memory, one click
  away in the popover (expand, switch CPU/Memory, click a row for PID, threads
  and the other resource). Samples only while visible.
- CLI `symtune processes [--sort cpu|memory] [--limit N] [--json]` and MCP tool
  `get_top_processes`. CPU is a measured rate between two sweeps, not `ps`'s
  average-since-boot; processes owned by other users are counted and reported as
  unreadable rather than silently dropped.
- The popover reports extended-brightness state honestly: waiting for HDR, or
  limited to the headroom the display grants.

### Changed
- Popover layout: a live CPU / memory / thermal strip under the title and two
  labelled groups (controls, system) instead of one long card stack.
- Popover performance: each polled value is read inside the smallest view that
  needs it, so a metrics tick no longer invalidates the whole panel body.
- A popover card added by a later release now joins an existing non-empty
  `[popover] cards` list instead of staying hidden for every existing config.
  An explicitly empty list is still honoured.
- **Security: stderr error redaction moved into SymTuneCore.** The CLI's error
  redaction logic (which scrubs credential material from provider error messages
  before they reach stderr or history) has been moved from the untested `symtune`
  executable target into `SymTuneCore` so it is covered by unit tests (#348).

## [0.9.1] — 2026-08-10

### Fixed
- MCP `keep_awake` durations are now bounded and validated: negative,
  non-finite, and durations above 86,400 seconds (24 hours) are rejected
  with a clear error, and the advertised tool schema exposes the accepted
  range (`#292`).

### Maintenance
- Added contributor guidance and a branch-protection emergency procedure;
  required CI checks now also run for documentation-only pull requests
  (`#294`).
- Added integration coverage for the public MCP stdio run path (`#293`).

## [0.9.0] — 2026-08-07

### Changed
- MCP server migrated from the hand-rolled JSON-RPC/stdio implementation to
  the shared `SymairaMCP` module from `symaira-appkit` (exact-pinned 0.8.1):
  `TuneMCPServer` registers `tools/list`/`tools/call` on
  `MCPServer.withMethodHandler(_:)` over `MCPStdioTransport`. The tool list
  (names, descriptions, schemas incl. safety bounds) is unchanged; the wire
  framing is now newline-delimited JSON-RPC per the MCP spec (`#285`).
- `symaira-appkit` is now pinned `exact: "0.8.1"` instead of `branch: "main"`
  (`#286`).

### Added
- AI usage tracking for 10 providers: OpenRouter, Nous Portal, Moonshot, Codex, GitHub Copilot, Kimi Code, OpenCode, Cursor, Antigravity, Claude (`#268`–`#281`).
- CLI `symtune ai-usage` command and MCP `get_ai_usage` tool (`#270`).
- AI usage popover card, preferences toggles, keychain-backed credentials, and menu-bar readout (`#281`).
- Cache backoff and in-flight cleanup for AI usage service (`#282`).
- SMC generation-aware temperature tables plus dynamic key enumeration (`#233`, `#240`).
- Battery Apple health numbers and live power draw reporting (`#234`, `#235`).

### Fixed
- Charge limit re-assertion after wake with hysteresis band (`#267`).
- SMC pre-override state persistence so a killed process cannot strand hardware (`#263`).
- Lapsed charge limit reporting with exact applied percent (`#262`).
- CLI `version --check-for-updates` waits for its notice before exiting (`#265`).
- CodeQL Action updated to 4.37.5 (`#283`).

## [0.8.1] — 2026-08-02

### Fixed
- Keep the EDR headroom claim without rendering visible overlay pixels, restoring cleanly at the neutral SDR multiplier (`#228`, `#229`).

## [0.8.0] — 2026-07-31

### Added
- Menu-bar app migrated onto the shared Symaira design system (`SymairaTheme` from `symaira-appkit`): type-scale text roles (`symairaText`), color/spacing/radius tokens, and the shared text field style (`#226`).

## [0.7.0] — 2026-07-31

### Added
- Configurable popover cards: choose which cards are visible in the menu-bar popover (system status, metric history, displays, display controls, keep-awake, fan control) via the preferences view; the selection is persisted in `~/.config/symtune/config.toml` under `[popover] cards` (`#218`).

### Fixed
- SMC availability reporting now reflects the truth per host, and the status popover no longer overflows on hosts without fans or SMC write access (`#217`).
- Status panel no longer re-renders wholesale on every interaction; EDR overlay crash fix (`#209`).

### Tests
- Config-load test isolation, SMC param-block and transport tests, EDR overlay routing tests, app metric-formatting logic extracted to the core and covered (`#220`–`#223`).

## [0.6.0] — 2026-07-30

### Added
- Auto-update check on app launch, gated by a settings toggle in Preferences. When an update is found, the menu-bar app now offers an in-app "Jetzt installieren" install button (`UpdateApplier.applyBundle()`) with download progress and error handling, falling back to the manual download link when no release assets are available (`#202`, `#208`).

## [0.5.0] — 2026-07-29

### Added
- System metrics service for CPU, memory, disk, and network utilization, exposed via CLI `symtune metrics` and MCP `get_system_metrics` (`#195`, `#196`, `#201`, `#203`).
- Preferences surface for metric selection, ordering, refresh interval and units (`#199`, `#204`).
- Live menu bar metric readout with monospaced digits, coexisting with the update badge (`#197`, `#205`).
- Rolling metric history with sparkline trends in the popover (`#200`, `#206`).

### Fixed
- Dim slider amount ↔ multiplier conversion fix (`#175`).

## [0.4.0] — 2026-07-29

### Added
- Keep-awake sessions with timer-based expiry, duration presets, display-sleep toggle and remaining-time display. New CLI `symtune awake --for <duration>`, `--until HH:MM`, `status`, `off`. Extended MCP `keep_awake` tool and app Keep Awake card (`#178`).
- Update checking via `SymairaUpdateCheck` (from symaira-appkit): non-blocking GitHub release check with skip-version persistence. The menu-bar app (`SymTuneApp`) shows a subtle update card with Download/Skip buttons when a newer version is available; skipped versions are persisted via `UserDefaults` and never re-prompted (`#173`).
- `SymairaUpdateCheck` SPM dependency: `symaira-appkit` (commit 019e506). Provides the high-level `AppUpdateChecker` ObservableObject with `SkippedVersionStore` protocol and `UserDefaultsSkippedVersionStore`.
- `SymTuneApp` target in `Package.swift`: the menu-bar app can now be built directly with `swift build` and run with `swift run SymTuneApp`.
- CI workflow split: fast PR gate (lint + ubuntu tests) on PRs, full suite on main pushes + weekly schedule, CodeQL reduced to weekly schedule.

### Fixed
- Software Dimming slider conversion between view dim amount and core brightness multiplier scale (`#175`).
- Fan control `restoreAuto()` now correctly throws `noFansDetected` when no fans are present, matching `applyFan` behavior. Fan Control card in the app is gated on fan availability (`#176`, `#177`).

## [0.3.1] — 2026-07-24

(This version was prepared but not released — content folded into 0.4.0.)

### Fixed
- `restoreAuto()` throws `.noFansDetected` instead of silently succeeding on Macs without controllable fans (e.g. fanless MacBook Air), and the menu-bar app's Fan Control card is gated on fan availability (`#179`).
- CI: quote the SPM package revision in `project.yml` so it is not parsed as a YAML float.

## [0.3.0] — 2026-07-17

### Added
- Fan control and battery charge limiting now ship in the open Apache-2.0
  core. New `fan set` / `fan auto` and `battery-limit set` /
  `battery-limit clear` CLI commands, plus matching `set_fan`,
  `set_charge_limit` and `clear_charge_limit` MCP tools. SMC writes require
  `sudo`, are clamped by `SafetyPolicy`, never disable firmware thermal
  protection, and restore the original SMC values on exit.
- `SMCWritePolicy` validation and SMC restore tracking for the new write
  paths, with unit tests across the controller, services and MCP tools
  (`#140`, `#141`, `#142`, `#143`).

### Fixed
- Correct `flt` byte order and map SMC write errors to `TuneError` instead of
  failing silently.
- Anchor the menu-bar status popover correctly below the menu-bar icon.
- Set the app delegate in the explicit main entry point of the menu-bar app.

### Changed
- `fan.control` and `battery.chargeLimit` are core-tier capabilities in
  `symtune doctor`. The previously planned privileged-helper requirement
  moved to an optional future convenience (see
  `docs/commercial-boundary.md`).

## [0.2.0] — 2026-07-13

### Added
- Standalone `SymairaTune.app` release packaging alongside the `symtune` CLI,
  including reproducible XcodeGen builds and bundle smoke checks (`#129`).
- Homebrew cask generation that installs the menu-bar app and links the CLI
  binary (`#129`).

## [0.1.4] — 2026-07-01

### Fixed
- Hardcoded tool version in `TuneVersion.current` is now synchronized with the release tag; release builds override it via `SYMTUNE_VERSION` so `symtune --version` matches the published release (`#112`).

### Added
- Release workflow verifies that the built binary reports the same version as the git tag before publishing the DMG (`#112`).

## [0.1.1] — 2026-06-23

### Fixed
- TuneConfig.load validates bounds against SafetyPolicy after parsing (`#72`).
- DimOverlay.deinit delegates to `removeAllOverlays()` for main-thread safety (`#73`).
- Dim overlay update continues for all displays in multi-monitor setups (`#74`).
- MCP transport rejects oversized Content-Length payloads (8 MB limit) (`#80`).
- MCP header overflow now throws instead of returning partial data (`#81`).
- EDR overlay no longer force-unwraps a raw MTLPixelFormat value (`#82`).
- `symtune version --check-for-updates` is non-blocking and writes to stderr (`#83`).
- Profiles no longer persist an unused `awake` field (`#84`).
- Unexpected CLI errors include full context, not just localizedDescription (`#85`).
- Restore-on-exit returns EDR to its prior headroom (`#86`).

### Changed
- MCP tool schemas include numeric bounds (`minimum`/`maximum`) (`#75`).
- MCPServer split into MCPTransport, MCPTool, MCPArguments, MCPTools (`#78`).
- UpdateChecker cache uses a private actor instead of `nonisolated(unsafe)` statics (`#77`).
- MCP transport hardens header parsing with proper terminator handling (`#89`).
- DisplayService extended brightness comment corrected (`#87`).
- Dead `TuneProfile.awake` field removed from model (`#88`).

## [0.1.0] — initial release

### Added
- Built-in display brightness get/set (`#20`).
- `config.toml` configuration file with `SYMTUNE_*` environment variable
  overrides (`#19`).
- Extended/EDR brightness, software dim overlay, warmth, restore-on-exit,
  profiles, and SMC sensor reads (`#49`). Fan curves, charge limiting, and
  DDC/CI are Pro-tier features (privileged helper required).
- Documentation sync for v0.1 feature set (`#65`).

### Fixed
- OverrideTracker signal handler: use `_exit()` instead of `exit()` to avoid
  re-entrant cleanup (`#48`).
- Orphan `SymairaTune` target moved to `docs/planned/` (`#66`).

### Security
- Profile name path traversal and 13 additional findings (`#35`).
- Security and correctness bugs from code review (`#63`).
- Restricted `GITHUB_TOKEN` permissions in CI workflows (`#67`).

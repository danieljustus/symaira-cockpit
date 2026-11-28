# Changelog

## [Unreleased]

### Fixed
- AI usage asks symbrain only for the providers enabled in the app (#394). The app called the
  agent's `ai-usage` without a selection, so symbrain discovered and queried every catalog
  provider, including disabled ones, and the app dropped the extra rows afterwards. The app
  now sends its enabled providers (`providers`), the agent passes them on as
  `--providers`, and credential references of other providers stay out of the child
  environment. With nothing enabled no request is made.

## [0.13.2] (2026-11-27)

### Fixed
- Cool and Max take effect through the privileged fan helper (#447). On 0.13.1 the agent
  started the helper's governor and dropped the connection right after the reply; the helper
  ends a governor when its last connection closes, so the fans went straight back to firmware
  control while the profile still read Cool or Max, without an error. The connection that
  starts the governor now stays open in the agent and carries the heartbeats until the
  governor is stopped. A one-shot `symcockpit fan profile comfort` from a terminal still ends
  the governor when the command exits; the app keeps it running.

## [0.13.1] (2026-11-27)

### Fixed
- Fan commands reach the privileged fan helper again (#430). The helper accepted only the
  app's signing identifier `com.symaira.cockpit`, while the bundled agent and CLI are signed
  as `com.symaira.cockpit.symcockpit`, so every connection was refused and writes fell back
  silently to the unprivileged path. The client requirement now accepts both identifiers
  (the Developer ID, team and forbidden-entitlement clauses are unchanged), connect failures
  are logged, and choosing Cool or Max starts or retargets the helper's governor while
  Standard stops it. `fan status` reports the governor.
- Stale fan overrides are handed back (#429): a failed apply rolls back the diagnostic unlock
  and manual mode, choosing Standard over an active override returns the fans to firmware
  control, and a profile switch without elevation is recorded as failed in the history.
  `fan status` shows the SMC override and each fan's mode and target.
- The Clipboard page's Delete All button uses the destructive button style.

### Performance
- The always-on notch HUD no longer redraws the whole display in software on every metrics
  sample (#418): its compact and peek readouts drew digits through a numeric text transition
  that ran a software Gaussian blur. They now draw the digits directly and skip unchanged
  values; the closed popover and cockpit window release their views. A local build dropped
  from 6.7 % to about 0.15 % idle CPU on a quiet machine.

### Changed
- The GUI uses native SwiftUI controls in place of the CoreKit controls deprecated in
  CoreKit 0.28.0 (grouped forms, progress views, switches, gauges and menus) (#440).
  VoiceOver names, preferences and agent commands are unchanged.

### Dependencies
- symaira-corekit 0.28.0; getrandom 0.4, jiff 1.0, sha2 0.11, sevenz-rust2 0.27, regex
  1.13.2, serde_json 1.0.154, tempfile 3.27, zip 9.8.2.

## [0.13.0] (2026-11-23)

### Fixed
- `symcockpit serve` reports its real version in `serverInfo.version` (it said 0.10.0 in
  v0.12.2); the version now comes from the binary itself (#422).
- The wake monitor fires after sleep: the v0.12 monitor compared against a wrong IOKit
  message constant, so display overrides and charge limits were never put back (#423).
- The Swift tests no longer write fake events into the real
  `~/.local/share/symtune/history.ndjson` (#424). Entries written by earlier test runs stay
  in that file until you remove them.

### Packaging
- Rust rebuild, wave 7: the release pipeline ships the Rust binary and is Apple Silicon only
  (architecture D16; Intel is not supported). `release.yml` builds
  `cargo build --release --locked -p symcockpit --target aarch64-apple-darwin` on the pinned
  toolchain and publishes `symcockpit_<version>_darwin_arm64.tar.gz` plus `checksums.txt`
  (`scripts/package-cli.sh`), replacing the universal Swift tarball
  `symcockpit_<version>_darwin_universal.tar.gz`. The app job builds the bundle arm64 only
  with the Rust agent, the privileged helper and both extensions, and no longer re-signs
  every Mach-O after the build: that re-sign sealed the Quick Look and FinderSync
  extensions without their sandbox and app-group entitlements. `scripts/build-app.sh` and
  `scripts/build-extensions.sh` sign nested parts first with one identity, Hardened Runtime
  and a secure timestamp (`CODE_SIGN_TIMESTAMP=--timestamp`), each part keeping its own
  entitlements; `scripts/smoke-app.sh` with `REQUIRE_RELEASE_SIGNATURE=true` verifies it.
  Notarization (`scripts/notarize.sh`) is fail-closed for the app and the DMG: only
  `status == Accepted` passes, then staple and validate; assets keep their names
  (`Symaira-Cockpit-<version>-macos.dmg`, `.zip`).
- Homebrew: the formula installs only the CLI (arm64 tarball, `depends_on arch: :arm64`,
  macOS 26); the cask installs the app and links `symcockpit` from inside the bundle
  (`binary`), with a wider `zap` (`~/.config|.cache|.local/share/symtune`, `~/.symtune`,
  the app group container, preferences). Homebrew has no way to declare the
  formula/cask conflict (a cask's `conflicts_with` accepts only `cask:`; a formula's
  `conflicts_with cask:` is ignored and crashes `brew style`), so installing both fails at
  the link step; the README says to install one. The Ruby files are templates in
  `packaging/homebrew/` rendered by `scripts/render-homebrew.sh` instead of shell
  heredocs in the workflow.
- One version source: `[workspace.package] version` in `Cargo.toml`. `scripts/set-version.sh
  <x.y.z>` writes it, the pins between crates, the workspace entries of `Cargo.lock` and
  `CockpitVersion.swift` (the GUI; the Info.plist files take it from there at build time).
  `scripts/check-version.sh` verifies they agree (CI `changes` job), equal the tag, the
  built binary's `version --json` and an assembled bundle (release workflow). CI gained an
  `app-bundle` job that assembles and smoke-checks the app ad hoc on arm64. A bump drill
  (0.12.3, `cargo test --locked`: 962 tests) found one test that pinned the version
  (`swift_bytes`); it now follows the build.
### Changed
- Rust rebuild, wave 2D-3 part 1: the window is a workspace with a sidebar of eleven
  destinations (Overview, Display, Power & Fans, Storage, Audio & MIDI, Bluetooth & Input,
  Processes, Clipboard, Finder, AI Usage, History) instead of one scrolling panel. While the
  agent cannot serve, the page shows why with a restart button. Risky changes use one shared
  plan confirmation that lists what will happen, how long the plan is valid and, afterwards,
  what happened to every entry. ⌘1 to ⌘9 switch pages.
- Storage and Processes add drive health and history, folder analysis and speed tests,
  plus reviewed plans for cleanup, duplicate removal, app removal and process termination.
- Audio & MIDI adds device routing, volume and mute, the app mixer, and reviewed format and
  aggregate-device changes. Bluetooth & Input adds paired-device status, explicit BLE scans,
  characteristic reads and planned writes, BLE log export, Finder cut and a haptic test.
- Clipboard adds an opt-in encrypted local history with exclusions, pause, copy and deletion.
  It is not exposed through MCP. Finder explains the extensions, their job location and
  how to enable them in System Settings.

### Internal
- The retired Swift fan helper is gone (#421): the `SymCockpitFanHelper` target,
  `FanControlService`, `FanGovernor`, the helper-side `SymCockpitHelperKit` files and their
  tests. They were still built but no longer shipped; the app bundles the Rust
  `symcockpit-helper`, whose launchd plist now lives in `crates/symcockpit-helper/`. This also
  removes the dead x86_64 path that addressed the 3-byte key `FS!` as key 0.
- `make oracle` and `make oracle-native` keep `BIN` paths with spaces intact (#425).
- The Rust toolchain pin moves to 1.98.1, which fixes a vtable miscompilation in 1.98.0 (#426).
- Rust rebuild, wave 2D-1: the Rust `symcockpit` no longer starts the Swift core for anything.
  `fan profile|target <value>` write the Swift file (`~/.symtune/fan-profile.json`) and the
  history line themselves (the app agent plans them as risky commands; `fan.target` takes
  `celsius`, `null` or `off` clears it); `status --watch` prints NDJSON until SIGINT, SIGTERM or
  a closed pipe; `ai-usage serve [--port N]` serves the cached usage on 127.0.0.1 with the v0.12
  routes, refusals and bytes (checked against the v0.12.2 binary); `version` runs the update
  check through `/usr/bin/curl` (3 s limit, one-day cache in the corekit file, same texts and
  JSON as v0.12.2); arguments that are not UTF-8 become U+FFFD as in Swift. `SYMCOCKPIT_LEGACY_BIN`,
  `symcockpit-legacy` and the `libexec` lookup are gone; a test plants a tripwire in all three
  places and runs every v0.12 command and MCP tool. Known difference: the texts of transport
  errors in a failed update check are Foundation's wording chosen from curl's exit status.
- Rust rebuild, wave 2D-2b: after the system wakes from sleep the Rust agent and
  `symcockpit serve` put back the display overrides they hold (warmth gamma table,
  extended brightness) and, on Apple Silicon, a charge limit they applied themselves
  (`IORegisterForSystemPower` on its own thread; the v0.12 monitor compared against
  a wrong message constant and never fired). The app passes
  `--finder-jobs-dir <app group container>/jobs` to its agent when the bundle names
  its app group (`SymCockpitAppGroup`, set by `build-app.sh` for team-signed
  builds). Real wake behaviour needs hardware (`docs/app-acceptance.md`).
- Rust rebuild, wave 2D-2: the app (menu bar, HUD, window) reads every value and
  runs every action through one app-wide agent session (`AgentSession`:
  `symcockpit agent --stdio` from the bundle, started at launch, stdin closed at
  quit). Views subscribe only while they are on screen; a failed, missing or
  version-conflicting agent is shown as a diagnosis with a manual restart, never
  as stale values; risky commands (fans) come back as a plan the user confirms in
  the app. `TuneController` is no longer used by the app or its UI. `build-app.sh`
  embeds the Rust `symcockpit` (agent and CLI) and `symcockpit-helper` (replaces
  the Swift helper under the same identity) with the team id baked in. Runbook for
  the runtime acceptance: `docs/app-acceptance.md`.
- Rust rebuild, wave 6 (R70-R73): `symcockpit-ffi` staticlib lists folders and ZIP, TAR and 7z
  archives with limits and never unpacks; Quick Look and FinderSync extensions are built by
  `scripts/build-extensions.sh` and embedded in the app (not registered or enabled; see
  `docs/extensions.md`); Finder context actions travel as job files with schema, expiry and an
  exclusive claim (`symcockpit-core::finder`); an opt-in, encrypted clipboard history for humans
  (`symcockpit-core::clipboard`, `symcockpit-db::clipboard`) with `clipboard
  status|pause|resume|clear` specs and no MCP or CLI read path. The CLI commands are not wired
  into `symcockpit` yet.
- Rust rebuild, wave 1: the Rust `symcockpit` answers every read command and read
  MCP tool natively (`sensors`, `fan status|profile|target`, `battery`,
  `awake status`, `displays`, `brightness get`, `metrics`, `processes`, `top`,
  `status`, `doctor`, `permissions`, plus `--help` of the write families). Only
  state-changing commands are still handed to the Swift core. The oracle passes
  70/70 with and without a Swift binary (`make oracle`, `make oracle-native`).
- Rust rebuild, wave 2C: `symcockpit agent --stdio`, the app's child process
  (JSON-RPC 2.0 as NDJSON: `hello` with protocol version, `call` through the
  MCP dispatch path with plan/confirm for risky commands, `subscribe` with
  visible/hidden intervals, measurement only while subscribed). It starts only
  under the signed Cockpit app (exit 3 otherwise; the test switch exists in
  debug builds only). Protocol: `docs/agent-protocol.md`; Swift client
  `AgentClient` in SymCockpitCore. The app does not use it yet.

- Rust rebuild, integration 2: the areas storage (`storage health|speedtest|space|clean|duplicates`,
  `apps uninstall`, `plan show|confirm`), audio and MIDI (`audio …`, `midi devices`),
  Bluetooth (`bt devices`, `ble scan|read|subscribe|write`), input (`input …`, CLI only) and
  ending a process (`processes kill <pid>`) are wired natively into the CLI and `serve`
  (24 new MCP tools next to the 26 of v0.12, with `readOnlyHint`/`destructiveHint`). Risky actions
  record a plan first; they run with `plan confirm <id>` or `<command> --confirm <id>`, at a
  terminal after a question; there is no `--yes`, and agents only get `plan_*` plus `confirm_plan`.
  Ending a process stores PID plus start time and path, checks them again at confirm, sends SIGTERM
  and reports confirmed, unconfirmed or failed. One `cockpit.sqlite` and one plan engine serve all
  areas; the oracle now demands the 26 v0.12 tools exactly and new tools only if declared and
  snapshotted.

## [0.12.2] (2026-11-18)

### Fixed
- **Hovered icons stop redrawing once their animation has settled** (#418):
  symaira-corekit 0.23.1 pauses the icon animation timeline after a hover or
  click motion. Before, every icon that had been hovered, for example in the
  notch HUD, kept redrawing at display rate until its view was torn down,
  which is a plausible cause of the CPU load that built up over a long
  session. Whether this resolves the reported 60 % load still needs
  confirmation in normal use.

### Changed
- symaira-corekit moves from 0.20.0 to 0.23.1 (#417). Running text uses
  Figtree instead of Inter; headings keep Google Sans Flex.

### Internal
- Test preference domains are created in the temporary directory instead of
  `~/Library/Preferences`, which collected an empty plist per test run (#419).
- The MCP protocol tests no longer query the host's AI providers through a
  real `symbrain`; the `get_ai_usage` test took up to 16 s on a configured
  Mac and timed out, and it touched the user's persistent usage cache.

## [0.12.1] (2026-11-12)

### Fixed
- **Returning the fans to firmware control works on Apple Silicon** (#414):
  `fan auto` and the helper's stale-override recovery wrote fan mode `3`,
  which an M4 Pro does not treat as automatic, so after a helper crash the
  fans stayed forced at full speed. They now write mode `0`, the value the
  firmware reports at rest. Verified live on a Mac16,8: after
  `kill -9` of the governing helper the fans sat at ~7,800 rpm with
  `Ftst=1`/`F*Md=1`; the fixed `fan auto` brought them back to ~2,300 rpm
  with `Ftst=0`/`F*Md=0`.

## [0.12.0] (2026-11-12)

### Removed
- **The `symcockpit tune <command>` prefix** (#259): deprecated through v0.8
  and v0.9, it now exits 2 and names the direct command instead of running
  it. Use `symcockpit <command>`; an MCP client configured with
  `["tune", "serve"]` needs `["serve"]`. The app's elevated fan and process
  calls already use the direct spelling.

### Fixed
- **Fan helper no longer crashes and leaves the fans at full speed:** the
  0.11.0 helper's idle-exit timer ran its main-actor-isolated handler on a
  private queue, so Swift 6's isolation check killed the helper (SIGTRAP)
  about a second after every start, including mid-governing. The fans then
  stayed forced at whatever the governor last wrote, and selecting *Standard*
  could not reach the dead helper. The idle timer and the SIGTERM handler now
  run on the main queue the helper's run loop drains.
- **Elevated `fan auto` no longer hangs:** restoring file ownership after a
  root write walked parent directories with `deletingLastPathComponent`,
  which climbs `..` forever for a relative location; as root every step
  stats as root-owned, so `sudo symcockpit fan auto` (and the GUI's
  administrator fallback) spun at full CPU and never restored the fans. The
  walk now steps through the components of the absolute path.
- **`fan auto` no longer claims success when nothing was restored** (#415):
  every SMC write is checked; a rejected one is still followed by the
  remaining writes, then reported as a permission error (exit 3) when
  unprivileged or an error (exit 1) as root, instead of `{"applied": true}`.
- **The fan helper recovers fans a dead predecessor left forced** (#414): at
  launch, and when *Standard* is chosen with no run active, the helper hands
  the fans back to the firmware if a software override (`Ftst` unlock, manual
  mode) is still set and no standalone `fan governor` process owns it. A
  `kill -9` mid-governing therefore no longer leaves the fans at full speed
  until someone runs `sudo symcockpit fan auto`.

## [0.11.0] (2026-11-11)

### Added
- **Fan rights take you to the right settings:** in a release-signed build,
  picking *Cool* or *Max* without the rights to change fans no longer runs into
  an administrator prompt. The control snaps back and Preferences opens at the
  *Privileged fan helper* section with a short explanation (helper off or not
  registered), or System Settings → Login Items opens (approval pending).
  *Standard*, a running governor, an enabled helper and unsigned/local builds
  keep their existing paths. The decision is a pure, tested Core function
  (`FanHelperRouting.selectionAction`).
- **Optional Cool target:** a *Max avg °C* field next to *Cool* (50–85 °C,
  empty = off) with the live average shown beside it. The fans follow the
  larger of the normal Cool curve at the hottest die and the same curve shifted
  to full speed at the target, evaluated at the mean CPU/GPU cluster
  temperature, so it only ever adds cooling. Bounds are clamped on write and on
  read, in the helper too; `fan-profile.json` gains an optional
  `cool_target_celsius` (older files still load). `symcockpit fan target
  <50-85|off>` sets it and `symcockpit fan status` (and `fan profile`) report
  `cool_target_celsius` and `average_cluster_celsius`. The XPC call to the
  helper carries the target, and the helper validates it again.
- **Fan helper survives upgrades:** the helper keeps its original XPC call
  (`startGovernor(profile:reply:)`, no target) and gets the target as an
  additional call, so a new app keeps controlling the fans through a
  still-running older helper. Such a helper is detected from one failed
  target request (remembered, never retried on later heartbeats), the fans stay
  governed on the normal Cool curve without a password prompt, and the Cool
  target row says the target is not applied yet. **After upgrading from 0.10.x
  the Cool target applies once the helper restarts: turn the helper off and on
  in Preferences, or restart your Mac. Future updates swap the helper
  automatically**, because it now exits a few seconds after its last client
  left and the fans were handed back (never while governing or connected).

### Changed
- **Cockpit window sidebar follows scrolling:** the *Jump to* entry of the section
  you are reading is selected while you scroll, not only after a click; at the
  end of the page the last section is selected.

## [0.10.2] (2026-11-11)

### Fixed
- **Fan helper could not be turned on (#411):** `SMAppService` reports a
  never-registered daemon as `notFound`, which the app read as "this build does
  not include the helper" and disabled the Preferences toggle, the only control
  that registers it. A bundled but never-registered helper now shows as off and
  can be enabled; "not included" remains for a bundle without the launchd plist.

## [0.10.1] (2026-11-10)

### Fixed
- **GUI fan control no longer elevates a stale root-owned `symcockpit` (#409):**
  after an upgrade, `/usr/local/bin/symcockpit` stayed at the old release
  (observed: 0.6.1 next to a 0.10.0 app) and was authenticated into root
  unchanged. Before the administrator prompt the app now runs the root-owned
  copy unprivileged (`version --json`, update check off, 5 s limit) and refuses
  a version that differs from its own, or one it cannot read, naming the path,
  both versions and the refresh command. `symcockpit doctor` gains the
  `fan.privilegedExecutable` capability reporting the resolved binary, its
  version and whether it matches. The root-ownership checks are unchanged.

## [0.10.0] (2026-11-10)

### Added
- **AI usage provider controls and local cost history (#394):** the provider
  catalog adds Z.ai, Devin, Grok and Ollama Cloud; providers are opt-in and
  can be starred, reordered and hidden. Reading local Claude, Codex, Grok and
  OpenCode session usage is a reversible opt-in, with recorded and estimated
  costs kept apart. An opt-in loopback API (`symcockpit ai-usage serve`, or the
  card's *Local usage API* switch, port 6737) serves cached snapshots on
  `127.0.0.1` only, for providers enabled in the app.
- **Total system power:** `symcockpit metrics` reports `power.system_watts`
  (SMC `PSTR`, falling back to the battery's `PowerTelemetryData.SystemLoad`)
  with `power.system_source` naming the origin. It is the whole Mac's
  consumption and stays meaningful on battery (#403).
- `power.adapter_watts` / `power.adapter_source` label the DC-in adapter input
  explicitly; `PD0R` is the fallback when `PDTR` reads 0 or is absent
  (desktops such as the Mac Studio) (#403).
- **GPU without root:** `symcockpit metrics` and the MCP `get_system_metrics`
  tool report GPU device utilization (`gpu.utilization_percent`, absent when
  the IORegistry publishes none), and `processes --sort gpu` ranks processes by
  GPU time read from the IORegistry's `AppUsage` counters, sampled twice. The
  root-only `powermetrics` path stays as the fallback when the registry exposes
  no `AppUsage`; the process card polls GPU like CPU and RAM (#402).
  GPU is also an opt-in metric row (`MetricIdentifier.gpu`): selectable in
  Preferences and `config.toml` (`[metrics] enabled/visible/order = [..., "gpu"]`),
  sampled into the metric history and shown in the history card, menu-bar
  readout and HUD item list. It is excluded from the default sets, so existing
  configs are unchanged, and a Mac that publishes no utilization shows no GPU
  row instead of 0 % (#402).
- **Optional privileged fan helper (#405):** a signed, notarized
  `Symaira Cockpit.app` can register an opt-in `SMAppService` daemon
  (`com.symaira.symtune-helper`) so fan changes need no administrator
  password and no root-owned CLI copy. Off by default; XPC is pinned to the
  Developer ID team on both sides; an app heartbeat (2 s) with a 7 s dead-man
  timeout, connection invalidation and SIGTERM hand the fans back to the
  system curve. Unsigned and local builds keep the `osascript` path unchanged.
  The expected Developer ID team is embedded at build time (read from the
  signing certificate in `release.yml`) and required on both ends; registration
  is refused while the bundle or helper is group/other-writable. The app keeps a
  helper-driven governor in line with the stored fan profile, so CLI/MCP
  `fan profile system` still ends it, and the card/HUD report the helper's
  governor as running.

### Changed
- The existing `power.volts`/`amps`/`watts` fields are unchanged and are now
  documented as adapter DC-in input only (about 0 on battery). The MCP
  `get_system_metrics` description and the `doctor` `power.draw.read` text say
  what each value measures (#403).
- **Login keychain for provider credentials (#396):** Cockpit has no
  keychain-access-groups entitlement, so the data-protection keychain refused
  every save (-34018). Items now use the login keychain through
  symaira-corekit 0.20, which replaces the symaira-appkit dependency.
- **Interface guidelines:** the menu-bar and HUD panels use the shared Symaira
  typography, colour and icon roles, and icon-only buttons carry accessibility
  labels and tooltips (#395).
- The `symcockpit tune …` prefix still works in this release; its removal waits
  for the remaining migration checks (#259).

### Fixed
- **Fan governor:** it hands the fans back to the firmware after three ticks
  without a governing temperature instead of holding the last speed, and it
  re-asserts or restores the fans when a read-back shows the firmware took over.
- **AI usage:** `ai-usage serve` only serves providers enabled in the app,
  disabling a provider deletes its cached snapshot, an oversized provider row
  fails on its own instead of turning the whole API into a 503, and the local
  server cannot race a quick disable/enable.
- The tuning XcodeGen project targets macOS 26 like the SwiftPM packages, so
  the menu-bar scheme builds again (#406).

### Security
- **Release workflow:** token permissions are scoped per job instead of
  workflow-wide `contents: write`, two pushes of the same tag can no longer race,
  and the Homebrew update waits up to 45 minutes for the tap PR (#404, #393).
- **Fan helper trust:** when the app bundle is owned by your user account (cask
  or drag install), software running as you could replace the helper, and a
  replaced helper runs as root once registered. The pinned team only stops it
  from pairing with the app. macOS App Management guards against this;
  `sudo chown -R root:wheel '/Applications/Symaira Cockpit.app'` closes it (#405).

## [0.9.0] (2026-10-26)

### Changed
- **Notch HUD:** the parked shoulders beside the camera cutout are 48 pt
  instead of 64 pt, so the HUD covers less of the menu bar. Strip readouts use
  a lighter, smaller face and a compact form with the full unit behind a
  narrow gap (`485 GB`, `37 %`); values scale to fit instead of being clipped,
  also while peeking (#374, #378, #381).
- **Edge HUD:** a peeking edge dock stacks each icon above its value, so long
  readouts such as `397 GB` no longer run into the screen edge (#385).
- **Memory readout:** memory used is counted the way Activity Monitor's
  components are (App Memory + Wired + Compressed), and used plus available
  always add up to physical memory. The previous figure counted active pages
  and sat over a gigabyte lower (#384, #386).
- The cockpit window lays its cards out as a two-column dashboard; the sidebar
  toggle lives in the toolbar and duplicate headings are gone (#335).
- The GUI is rebuilt on the shared Symaira AppKit workspace (#356).
- Tune/SymTune is no longer a visible module name: `symcockpit version`,
  help, error prefixes, the MCP server identity (`symcockpit`) and the
  doctor/capabilities `tool` field use Cockpit naming. Grandfathered
  Keychain/UserDefaults/helper identifiers are unchanged (#337, #338, #339,
  #340).
- Refreshed Liquid Topography brand assets, re-rendered with smooth contours,
  and the approved K1v2 app icon (#371, #372, #380).
- Consolidate window settings in one native trailing gear menu, with
  System/Light/Dark choices and the existing full-settings action. Remove
  duplicate sidebar and parent-toolbar settings entries (#354).
- **Liquid Topography design (approved pilot, revision 08):** the Cockpit
  window, popover and preferences follow the system appearance instead of a
  fixed dark canvas and use the shared Symaira AppKit roles. Google Sans Flex
  replaces SF Pro. Light-mode selection is ink, dark-mode selection champagne;
  segmented choices, switches and slider thumbs use the shared
  `SymairaSegmentedControl` / `.symairaSwitch` components. Start/Apply actions
  are opaque ink buttons. The compact notch/edge bezel stays black; expanded
  HUD cards follow System/Light/Dark with shared type, neutral surfaces and
  action buttons. Larger rows remain scrollable on short displays (#357).
- The window uses AppKit's reactive Metal topography behind protected content,
  a 272-point glass sidebar with visible selection/focus, and a compact icon
  rail. Settings and popovers remain quiet, opaque surfaces; HUD customization
  uses a full-width row so its controls fit.

### Fixed
- Bundle the AppKit font, license, compiled shader and provider resource
  bundles with the app; bundle smoke checks reject missing resources (#351).
- Protect headings and descriptions at their own text bounds rather than
  blanking the entire title stack or section divider row behind the topography
  (#354).
- AI usage: OpenRouter, Moonshot and Kimi can point at an existing SymVault
  entry (for example `openrouter/work`) instead of the fixed
  `symtune/<provider>` path. Only the opaque path is stored; an enabled
  provider without a usable entry stays on the card with the reason instead of
  disappearing (#376, #377).
- Brightness keys: an untrusted brightness read hands the key press back to
  macOS, and each press has exactly one owner (#359, #360, #373).
- Ending a HUD drag no longer depends only on the gesture's own end event; a
  cancelled drag can no longer leave an invisible full-screen panel capturing
  all mouse and keyboard input (#382).

### Added
- Debug builds offer `--hud-demo`: the real screen-docked HUD with labelled
  example values, hover/click/drag, position and appearance controls. It starts
  no hardware model and keeps all settings in memory (#357).
- Debug builds support `--design-preview` (with `--light`, `--dark`,
  `--compact` or `--no-readings`) for native review without hardware polling,
  credential access or preference writes. Release builds exclude this path.
- A shared Storage Volumes card lists user-visible mounted internal, external
  and network/virtual volumes with mount paths and total/used/available space.
  Mount, unmount and rename notifications refresh the list; `metrics` and
  `get_system_metrics` expose the same data. Existing boot-volume metrics and
  card visibility choices remain compatible (#330).
- A native Choose menu shows or hides individual storage volumes in both
  panels, saving the selection automatically. Filesystem UUIDs keep choices
  across renames/reconnects; new volumes remain visible and an all-hidden list
  keeps the menu reachable. CLI/MCP discovery remains complete (#331).

### Known limitations
- The fluid edge-pull drag animation from #379 was reverted after the
  hands-on check (#383); #375 stays open until the intended look is pinned down.
- AI usage's custom SymVault entry is a GUI preference; CLI/MCP processes keep
  the default `symtune/<provider>` reference.
- Native keyboard/VoiceOver acceptance remains deferred in #305. The legacy
  `symcockpit tune` prefix remains supported through v0.9; its removal belongs
  to v0.10 (#259).

## [0.8.1] (2026-10-10)

### Fixed
- Keep decoded metric history within its configured capacity and retain the
  newest samples without changing the JSON shape (#324, #325).
- Show contextual `profile` and `history` help before executing operations,
  preserving stored profiles and history when `--help` or `-h` is requested
  (#326, #327).
- Resolve Swift callback-isolation and bounded process-name decoding
  diagnostics, with regression and Release-build checks (#315, #323).
- Isolate display-write unit tests through the shared mock boundary, including
  dimming and restore-on-exit cleanup (#316, #323).
- Install and verify the reviewed custom DMG volume icon after Finder layout
  so it survives conversion and the final read-only mount (#321, #323).
- Publish CLI Formula and GUI Cask updates through protected Homebrew pull
  requests using exact release-asset checksums (#320).

### Known limitations
- Native keyboard/VoiceOver acceptance remains explicitly deferred in #305.
- The legacy `symcockpit tune` prefix remains supported through v0.9; its
  removal and final migration checks belong to v0.10 (#259).

## [0.8.0] — 2026-10-03

### Added
- `doctor`, `permissions`, `history`, and `serve` now work directly under
  `symcockpit`, completing the command map after Operate and Scope moved to
  Brain (#259).
- Hardware-isolated Debug SwiftUI previews reuse the production components
  with labelled fixtures and local-state-only controls (#310).

### Changed
- The GUI opens directly into the shared tuning panel inside a quiet,
  collapsible workspace. In-page shortcuts preserve draft values; narrow
  windows use an icon rail, and the Symaira dark/gold palette is unchanged
  (#307, #311).
- Display and fan sliders use rounded rails, guide dots and light circular
  knobs. Display ranges remain continuous and fan detents retain the existing
  Standard, Cool and Max temperature curves and permission checks (#311).
- Status cards use readable labels, accessible control names and explicit
  loading states instead of reporting missing readings as healthy (#309).
- The `symcockpit tune …` prefix emits a stderr deprecation warning while
  retaining the same command behavior, including JSON/MCP stdout. It remains
  supported through the next two minor releases (v0.8 and v0.9), with removal
  planned for v0.10 after migration checks (#259).
- Release artifacts are stripped before packaging: the CLI tarball and the
  app executable no longer ship the full Swift symbol table (112k symbols,
  more than half the binary size). The CLI keeps an ad-hoc signature so it
  still execs on arm64; the app is stripped before its Developer ID
  signature.

### Fixed
- Reject trailing CLI arguments before any mutation, validate refresh intervals
  before saving, and reject unrepresentable charge percentages without crashing
  (#286, #288, #289).
- Serialize history recovery, appends and retention across processes; service
  main-queue work during the MCP stdio loop (#287, #292).
- Embedded Tune reports `0.10.0` with the unchanged version JSON schema (#278,
  #306). It remains a component of the sole shipped `symcockpit` CLI.
- Document public fan/charge-limit capabilities and the actual coverage graph;
  malformed Debug preview fixtures fail explicitly without forced decoding or
  fabricated fallback readings (#313, #314).

### Known limitations
- Native keyboard/VoiceOver acceptance remains explicitly deferred in #305.
- Compiler warnings and legacy display-write unit-test isolation remain tracked
  separately in #315 and #316; they are not presented as completed acceptance.

## [0.7.0] — 2026-09-22

Tune-only product cutover (PB-2026-09-09): Symaira Cockpit is now only the
macOS hardware/system-tuning product. Operate and Scope are optional Symaira
Brain modules.

### Added
- Most tune commands now also work without the `tune` prefix (for example
  `symcockpit sensors` == `symcockpit tune sensors`). `symcockpit tune
  <command>` keeps working unchanged; the four colliding names (doctor,
  permissions, serve, history) stay reachable only via `tune` (#260).

### Changed
- **Breaking: `symcockpit operate` and `symcockpit scope` are removed.** The
  Operate and Scope packages, dispatcher commands, GUI sections and related
  tests were retired from Symaira Cockpit; the capabilities live in Symaira
  Brain as optional modules. Legacy callers get a migration hint — install
  from a Brain checkout with `symbrain setup --from-source <brain-checkout>
  --modules operate,scope` — and exit 4 (#267, #277).

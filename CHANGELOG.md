# Changelog

## [Unreleased]

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

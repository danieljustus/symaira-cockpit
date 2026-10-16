# Changelog

## Unreleased

### Changed
- Consolidate window settings in one native trailing gear menu, with
  System/Light/Dark choices and the existing full-settings action. Remove
  duplicate sidebar and parent-toolbar settings entries (#354).
- **Liquid Topography design (approved pilot, revision 08):** the Cockpit
  window, popover and preferences follow the system appearance instead of a
  fixed dark canvas and use the shared Symaira AppKit roles. Google Sans Flex
  replaces SF Pro. Light-mode selection is ink, dark-mode selection champagne;
  segmented choices, switches and slider thumbs use the shared
  `SymairaSegmentedControl` / `.symairaSwitch` components. Start/Apply actions
  are opaque ink buttons. The notch and dock HUD stay dark on purpose. Requires
  the unreleased AppKit Liquid Topography change (pinned by revision until it
  is tagged).
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

### Added
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

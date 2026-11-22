# Cockpit workspace design

## Contract

The macOS window uses the shared `SymairaTheme` Liquid Topography workspace, not a chat application. Semantic colors and Google Sans Flex typography follow the System/Light/Dark appearance choice. There is no new third-party dependency, cloud behavior, product module, or hardware-control implementation.

- `CockpitWorkspaceView` is the shared shell (`SymairaWorkspace`): a sidebar with one `SymairaNavigationButton` per `CockpitDestination` (Overview, Display, Power & Fans, Storage, Audio & MIDI, Bluetooth & Input, Processes, Clipboard, Finder, AI Usage, History), one mounted page at a time, the toolbar's sidebar toggle and settings gear, and one status line (`Agent connected`, `Agent starting…`, `Agent not reachable`). The real window and the debug-only component preview share this chrome. Settings stay in `PreferencesView`, opened by the gear.
- The window selection is a `CockpitNavigation` owned by the AppKit host. The main menu's **Navigate** items (⌘1 to ⌘9 for the first nine destinations) and the sidebar act on it.
- While the agent cannot serve, the page area shows it instead of readings: a loading state while it starts, `AgentDiagnosisCard` with a restart when it failed. Pages therefore never draw zeros.
- `MainStatusView` is the menu-bar popover only and stays the compact panel. The window does not embed it: its pages (`OverviewPage`, `DisplayPage`, `PowerFansPage`, `AIUsagePage`, `HistoryPage`) compose the same cards and view models (`TuneViewModel`, `AIUsageViewModel`), so nothing is built twice. `StatusBarController.cockpitWorkspace(...)` builds them.
- Storage, Audio & MIDI, Bluetooth & Input, Processes, Clipboard and Finder are `<Name>Page.swift` placeholders ("Not available yet"). Each takes the app's `AgentSession` and nothing else; wave 2D-3 part 2 replaces those files only.
- `PlanConfirmationView` (logic in `SymCockpitCore.PlanConfirmationModel`) is the one place where a risky command's plan is shown and approved: command, entries with target and size, expiry countdown, Cancel and the applying verb, then the result per entry (`confirmed`, `skipped_changed`, `failed`, ...). Fans and the charge limit use it; so will every later risky action.
- The Menu bar & HUD readout cards sit at the bottom of Overview. The popover's card-visibility preferences do not hide cards on window pages.
- Open plans are not listed on History: the agent can show one plan by id (`plan.show`) but offers no list of plans.
- The shared sidebar policy switches to a 64 pt icon rail when the available width cannot fit its minimum expanded width plus the content reserve. The user's expanded/collapsed choice and preferred width survive automatic compact layout. The window's minimum size is 840 × 560 pt, the shell's default sidebar plus the content reserve.
- Window typography and card padding use the embedded chrome environment; the compact popover retains its own spacing. Native controls inherit the selected app appearance.

## Sliders

Display and fan controls reuse `EffortSlider`, a native `NSSlider` with an 8 pt capsule rail, inset guide dots and a 20 pt circular knob. The rail, fill and thumb use the same adaptive neutral colors as the meters. The shared display rows retain their original value ranges. Continuous display guide dots do not enable native tick snapping; the centre-anchored row still snaps pointer drags to Normal, while non-drag actions commit without trapping small steps at zero.

`FanProfileSliderRow` selects only the existing Standard, Cool and Max profiles, with native detents from `FanProfile.ordered`. It does not expose arbitrary RPM. Pointer edits remain local until release; the existing fan binding, authorization, rollback and temperature-dependent safety curves remain in charge. The slider is disabled while authorization is pending.

## Hardware boundary

`Sources/SymCockpitApp/CockpitRootView.swift` embeds the workspace from `statusBar.cockpitWorkspace(...)` once. It owns no tuning logic. Hardware control, credential access, fan authorization, polling, brightness arithmetic and display gamma remain in the existing production services. HUD geometry belongs to `SymCockpitCore`; appearance and docking preferences retain their production persistence boundaries.

`tuning/project.yml` already includes all of `Sources/SymCockpitUI` through its source-directory entry, matching SwiftPM's discovery of the new file. No duplicated file list or Xcode project is introduced.

## Notch and edge HUD

The HUD consumes the existing Liquid Topography `SymairaTheme` semantic colors,
Google Sans Flex typography and shared primary/secondary button styles. There
is no HUD-local palette or new AppKit dependency. Expanded cards inherit the
same System/Light/Dark choice as the workspace; the camera strip and collapsed
or peeking edge bezel stay black with explicitly dark-surface readouts.

Dense HUD cards use quiet opaque surfaces, not a moving topography behind small
numbers. The camera clearance, screen-edge anchoring, drag and three-stage
presentation remain intact. Expanded shoulders retain the peek width, bounded
by the actual card width and camera gap, rather than clipping peek items back
into collapsed shoulders. The shared row-height budget matches the larger
type; constrained displays scroll the readings while keeping actions visible.

`HUDDesignTests` mounts the production HUD in passive native panels with test
values, never a hardware controller. It checks notch/left/right shapes, every
stage, both appearances, empty/full content, and updates in an already mounted
HUD. Native component captures are not live docking, pointer or VoiceOver
acceptance. Set `COCKPIT_HUD_RENDER_DIR` to export these fixture renders.

For hands-on review, launch the Debug app with `--hud-demo` (optionally
`--light` or `--dark`). This mounts the production `HUDDockController` on the
actual screen with labelled example values and an in-memory preference store.
The control window chooses the dock, appearance and visibility; hovering,
clicking and dragging use the production event path. Closing that window or
choosing **Demo beenden** removes the HUD and quits only the demo process.
No hardware model, polling, credentials or persistent tuning settings are used.

## Review

`CockpitDesignPreview` is compiled only in DEBUG. It uses passive production cards and explicitly labelled fixtures. Its controls, including the real passive fan-profile slider row, write local SwiftUI state only. Fan hardware behavior, live Activity and HUD behavior require the real app; the preview labels those sections rather than synthesizing data or starting controllers. The production app bundle is built and smoke-checked separately. A preview screenshot is design evidence, not live hardware evidence.

Verification commands:

For design work in full Xcode, open the root `Package.swift`, then open `tuning/Sources/SymCockpitUI/CockpitDesignPreview.swift` in the local tuning package. Enable **Editor → Canvas** and resume one of the named **Breit**, **Kompakt**, or **Ohne Messwerte** previews in a Debug configuration. These previews do not launch the production application; never replace their passive components with `TuneController` or the live root view merely to fill a missing section.

```sh
swift build --product SymCockpitApp --jobs 2
swift test --jobs 2
make test
make build
```

`CockpitGUIContractTests` guards the shell, one placeholder file per area with only the session, the absence of a `TuneController` dependency in the window, component reuse and accessibility labels. `CockpitPagesTests` covers the destinations, the status line and the formatting of the plan view; `PlanConfirmationTests` and `PageModelTests` (SymCockpitCoreTests) run the confirmation, history and profile models against the fake agent. `CockpitPreviewContractTests` validates fixture decoding and the absence of model, credential and hardware lifecycle calls. `EffortSliderTests` checks native knob endpoints/centre, fan detents and binding feedback. Runtime review additionally checks native sidebar actions, scroll destinations and reversible local control changes. Native target/action checks in an inactive component-render host verify callbacks, not physical keyboard delivery or VoiceOver. Compare an unmodified native control before interpreting an inactive-host input no-op as a production defect.

`CockpitNativeInteractionTests` exercises sidebar and appearance AX actions on the production views while checking retained slider identity and value. Its passive hosts enable SwiftUI accessibility and temporarily establish AppKit's process-local assistive-client state, restoring that state afterward. The walker selects descendant buttons before toolbar containers that mirror their names and roles. It requires no cross-process AX-trust grant and does not skip the interaction for missing trust; this is not physical keyboard or VoiceOver acceptance.

Private user references and local screenshots are not committed. This source redesign does not constitute an app installation, release or notarized distribution.

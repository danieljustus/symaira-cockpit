# Cockpit workspace design

## Contract

The macOS window uses the shared `SymairaTheme` Liquid Topography workspace, not a chat application. Semantic colors and Google Sans Flex typography follow the System/Light/Dark appearance choice. There is no new third-party dependency, cloud behavior, product module, or hardware-control implementation.

- `CockpitWorkspaceView` owns only the sidebar, scroll container and appearance. The sidebar toggle sits in the window toolbar; there is no separate in-page header row. The real window and debug-only component preview share this chrome.
- `MainStatusView` remains the one shared tuning panel. The popover keeps its compact presentation. The window groups the same production controls into Overview, Display, Power & cooling, Activity, and Menu bar & HUD.
- Sidebar buttons are explicitly **Jump to** links, not fake page tabs. They scroll to typed anchors inside one mounted panel. Navigating does not recreate slider or keep-awake draft state.
- The shared sidebar policy switches to a 64 pt icon rail when the available width cannot fit its minimum expanded width plus the content reserve. The user's expanded/collapsed choice and preferred width survive automatic compact layout. The existing 620 pt minimum window width is retained.
- Window typography and card padding use the embedded chrome environment; the compact popover retains its own spacing. Native controls inherit the selected app appearance. Reduce Motion disables animated section jumps.

## Sliders

Display and fan controls reuse `EffortSlider`, a native `NSSlider` with an 8 pt capsule rail, inset guide dots and a 20 pt circular knob. The rail, fill and thumb use the same adaptive neutral colors as the meters. The shared display rows retain their original value ranges. Continuous display guide dots do not enable native tick snapping; the centre-anchored row still snaps pointer drags to Normal, while non-drag actions commit without trapping small steps at zero.

`FanProfileSliderRow` selects only the existing Standard, Cool and Max profiles, with native detents from `FanProfile.ordered`. It does not expose arbitrary RPM. Pointer edits remain local until release; the existing fan binding, authorization, rollback and temperature-dependent safety curves remain in charge. The slider is disabled while authorization is pending.

## Hardware boundary

`Sources/SymCockpitApp/CockpitRootView.swift` embeds the workspace and the existing `statusBar.tunePanel(chrome: .embedded)` once. It owns no tuning logic. Hardware control, credential access, fan authorization, polling, brightness arithmetic and display gamma remain in the existing production services. HUD geometry belongs to `SymCockpitCore`; appearance and docking preferences retain their production persistence boundaries.

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

`CockpitGUIContractTests` guards one shared panel, all five unique scroll anchors, component reuse, accessibility labels, compact navigation and Reduce Motion. `CockpitPreviewContractTests` validates fixture decoding and the absence of model, credential and hardware lifecycle calls. `EffortSliderTests` checks native knob endpoints/centre, fan detents and binding feedback. Runtime review additionally checks native sidebar actions, scroll destinations and reversible local control changes. Native target/action checks in an inactive component-render host verify callbacks, not physical keyboard delivery or VoiceOver. Compare an unmodified native control before interpreting an inactive-host input no-op as a production defect.

`CockpitNativeInteractionTests` exercises sidebar and appearance AX actions on the production views while checking retained slider identity and value. Its passive hosts enable SwiftUI accessibility and temporarily establish AppKit's process-local assistive-client state, restoring that state afterward. The walker selects descendant buttons before toolbar containers that mirror their names and roles. It requires no cross-process AX-trust grant and does not skip the interaction for missing trust; this is not physical keyboard or VoiceOver acceptance.

Private user references and local screenshots are not committed. This source redesign does not constitute an app installation, release or notarized distribution.

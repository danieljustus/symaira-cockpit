# Cockpit workspace design

## Contract

The macOS window uses a quiet Codex/ChatGPT-inspired workspace layout, not a chat application. The existing `SymairaTheme` dark/gold palette remains authoritative. There is no new third-party dependency, cloud behavior, product module, or hardware-control implementation.

- `CockpitWorkspaceView` owns only the sidebar, workspace header, scroll container and appearance. The real window and debug-only component preview share this chrome.
- `MainStatusView` remains the one shared tuning panel. The popover keeps its compact presentation. The window groups the same production controls into Overview, Display, Power & cooling, Activity, and Menu bar & HUD.
- Sidebar buttons are explicitly **Jump to** links, not fake page tabs. They scroll to typed anchors inside one mounted panel. Navigating does not recreate slider or keep-awake draft state.
- Below 840 pt window width the sidebar automatically becomes a 64 pt icon rail. The user's expanded/collapsed choice survives automatic compact layout. The existing 620 pt minimum window width is retained.
- Window typography and card padding use the embedded chrome environment; the compact popover retains its original spacing. Native controls use dark appearance on the fixed dark canvas. Reduce Motion disables animated section jumps.

## Sliders

Display and fan controls reuse `EffortSlider`, a native `NSSlider` with an 8 pt capsule rail, inset guide dots, a 20 pt light circular knob and the existing gold active colour. The shared display rows retain their original value ranges. Continuous display guide dots do not enable native tick snapping; the centre-anchored row still snaps pointer drags to Normal, while non-drag actions commit without trapping small steps at zero.

`FanProfileSliderRow` selects only the existing Standard, Cool and Max profiles, with native detents from `FanProfile.ordered`. It does not expose arbitrary RPM. Pointer edits remain local until release; the existing fan binding, authorization, rollback and temperature-dependent safety curves remain in charge. The slider is disabled while authorization is pending.

## Hardware boundary

`Sources/SymCockpitApp/CockpitRootView.swift` embeds the workspace and the existing `statusBar.tunePanel(chrome: .embedded)` once. It owns no tuning logic. No changes are made to `SymTuneCore`, credential access, fan authorization, polling, brightness arithmetic, display gamma or preference persistence.

`tune/project.yml` already includes all of `Sources/SymTuneUI` through its source-directory entry, matching SwiftPM's discovery of the new file. No duplicated file list or Xcode project is introduced.

## Review

`CockpitDesignPreview` is compiled only in DEBUG. It uses passive production cards and explicitly labelled fixtures. Its controls, including the real passive fan-profile slider row, write local SwiftUI state only. Fan hardware behavior, live Activity and HUD behavior require the real app; the preview labels those sections rather than synthesizing data or starting controllers. The production app bundle is built and smoke-checked separately. A preview screenshot is design evidence, not live hardware evidence.

Verification commands:

For design work in full Xcode, open the root `Package.swift`, then open `tune/Sources/SymTuneUI/CockpitDesignPreview.swift` in the local Tune package. Enable **Editor → Canvas** and resume one of the named **Breit**, **Kompakt**, or **Ohne Messwerte** previews in a Debug configuration. These previews do not launch the production application; never replace their passive components with `TuneController` or the live root view merely to fill a missing section.

```sh
swift build --product SymCockpitApp --jobs 2
swift test --jobs 2
make test
make build
```

`CockpitGUIContractTests` guards one shared panel, all five unique scroll anchors, component reuse, accessibility labels, compact navigation and Reduce Motion. `CockpitPreviewContractTests` validates fixture decoding and the absence of model, credential and hardware lifecycle calls. `EffortSliderTests` checks native knob endpoints/centre, fan detents and binding feedback. Runtime review additionally checks native sidebar actions, scroll destinations and reversible local control changes. Native target/action checks in an inactive component-render host verify callbacks, not physical keyboard delivery or VoiceOver. Compare an unmodified native control before interpreting an inactive-host input no-op as a production defect.

Private user references and local screenshots are not committed. This source redesign does not constitute an app installation, release or notarized distribution.

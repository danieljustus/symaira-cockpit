# Planned Features

These files contain service implementations that are not yet wired into the
main `TuneController` facade. They are kept here for reference and will be
integrated when the corresponding features are ready.

## Files

### SymairaTune/ (AppDelegate.swift, StatusBarController.swift, Info.plist)
Menu-bar application for `symaira-tune`. A status-bar-only `LSUIElement` app
(no dock icon) that surfaces sensor/battery/display reports in a dropdown
menu. The `xcodegen` `project.yml` and generated `SymairaTune.xcodeproj` are
the canonical build path for this target — it is not wired into `Package.swift`
because SPM does not produce a real macOS `.app` bundle.

**Planned for:** v0.2 menu-bar app per `docs/roadmap.md`.

### DDCService.swift
DDC/CI (Display Data Channel Command Interface) service for controlling
external monitor brightness, contrast, and input selection. Requires I2C
access via IOKit, which needs a C bridging header for proper Swift access.

**Planned for:** External monitor brightness/contrast control via DDC/CI.

## Integration Path

When ready to integrate:
1. Move files back to `Sources/SymTuneCore/` (or to `Sources/SymairaTune/` for
   the menu-bar app, paired with a new executable target in `Package.swift`
   *or* a properly built `.app` bundle from the existing `project.yml`).
2. Wire into `TuneController` with the same facade pattern used for display
   and SMC features.
3. Update capabilities report to reflect available features.
4. Add CLI commands and MCP tools for the new features.

## Notes

- These files compile but contribute nothing to the shipped product.
- Fan control and battery charge limit were previously planned here; they
  have moved to the open core in v0.3.

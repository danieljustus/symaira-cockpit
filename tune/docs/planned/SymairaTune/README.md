# SymairaTune (menu-bar app) — planned for v0.2

These files implement the `symaira-tune` menu-bar app: a status-bar-only
`LSUIElement` macOS app (no dock icon) that surfaces sensor, battery, and
display reports in a dropdown menu driven by `TuneController`.

They live in `docs/planned/` rather than `Sources/` because:

- The v0.1 SPM build (`swift build`) does **not** include this target —
  `Package.swift` deliberately omits it. SPM produces a CLI binary, not a
  macOS `.app` bundle, which is what a menu-bar app needs.
- The canonical build for this target is the `xcodegen` `project.yml` at the
  repo root, which generates `SymairaTune.xcodeproj`. Run
  `xcodegen generate` from the repo root to (re)generate the project.
- Wiring a target here would be misleading: a successful `swift build` would
  not produce a runnable menu-bar app, and Swift 6 strict-concurrency
  AppKit isolation still needs follow-up work in `StatusBarController`.

## Files

- `AppDelegate.swift` — `NSApplicationDelegate` for the menu-bar app.
- `StatusBarController.swift` — `NSStatusItem` lifecycle and dropdown menu.
- `Info.plist` — `LSUIElement=true`, bundle metadata.

## Known follow-ups (deferred to v0.2 wiring)

These were flagged by the 2026-06-18 code review and are intentionally
**not** addressed in the move:

- `StatusBarController` swaps `statusItem.menu` to a submenu and back via a
  `DispatchQueue.main.asyncAfter(0.1)` to repaint the root menu. The right
  fix is `NSMenuItem.submenu` (no swap, no delay).
- `TuneController` calls are not wrapped in `do/catch`; failures silently
  swallow.
- `TuneController.sensors_report()` is `snake_case`; siblings
  (`batteryReport`, `displaysReport`) are `camelCase`. Aligning the public
  API is a separate breaking change for the CLI and MCP layer.

## Build (when v0.2 lands)

```bash
xcodegen generate          # regenerate SymairaTune.xcodeproj from project.yml
xcodebuild -project SymairaTune.xcodeproj -scheme SymairaTune -configuration Release
```

Or open `SymairaTune.xcodeproj` in Xcode and Run.

# Agent Instructions — symaira-operate

Native macOS desktop-automation MCP server (Swift 6 toolchain, AppKit /
ApplicationServices / ScreenCaptureKit). Lets an AI agent observe and drive the
Mac GUI: screenshots, the Accessibility tree, mouse/keyboard input, and app/
window control — locally, over stdio MCP. Public repo, Apache-2.0-licensed. Part of the
Symaira family — see `../AGENTS.md` / `../ECOSYSTEM.md`.

It is the agent-native sibling of `symaira-tune` (hardware knobs): operate = GUI
actions, tune = thermals/brightness/power.

## Build & Test

```bash
swift build
swift test
swift run -q symoperate doctor
```

Local toolchain note: if Command Line Tools `swift` is broken (dyld errors), use
the Xcode(-beta) toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
```

## Module Layout (SPM)

```
symoperate (executable)  →  SymOperateMCP  →  SymOperateCore
```

- `SymOperateCore` — automation logic and the only target touching AppKit/AX/
  ScreenCaptureKit: `ScreenService` (capture), `AccessibilityService` (AX tree +
  ephemeral `element_id` cache), `InputService` (CGEvent mouse/keyboard),
  `AppService` (apps/windows), `PermissionService`, `AutomationController`
  (orchestration + safety guards).
- `SymOperateMCP` — stdio JSON-RPC/MCP transport; tool schemas + arg validation.
- `symoperate` — CLI: `serve`, `doctor`, `permissions status|grant`.

## Hard Rules (safety-critical — this tool drives the user's machine)

- **Supervised & local only**: stdio MCP, no remote transport, no daemon. The
  agent plans; symoperate executes one bounded action and returns fresh state.
- **Destructive-action guard stays on**: element-based actions refuse controls
  whose label/role matches Delete/Remove/Erase/Trash/Uninstall/Allow/Authorize/
  Unlock/Quit/Force Quit. `AXSecureTextField` is blocked. Never weaken these.
- **Never automate** password, payment, permission-dialog, or account-recovery
  flows without explicit user confirmation.
- **Prefer `query_ui` + `element_id` over raw coordinates.** `element_id`s are
  ephemeral (bounded FIFO cache); after a UI change, re-snapshot — don't reuse.
- **Zero stdout pollution in `serve`**: stdout is JSON-RPC frames only; logs to
  stderr.
- Requires `Accessibility` and `Screen Recording` permissions (the host process
  must be authorized). `doctor` verifies and explains.

## Conventions (ecosystem)

- Binary: `symoperate`. Exit `0` ok / `1` error.
- Distribution: notarized direct / Homebrew cask (not the Mac App Store — AX +
  Screen Recording automation cannot be sandboxed for the App Store).

See `docs/architecture.md` and `docs/roadmap.md`.

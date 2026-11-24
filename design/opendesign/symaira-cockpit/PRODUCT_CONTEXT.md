# Product Context — Symaira Cockpit

**Repository:** `/Users/daniel/Dev/Symaira Dev/symaira-cockpit`
**Product role:** Native macOS CLI, MCP server, menu-bar app, and cockpit window for Tune, Operate, and Scope.

## Product focus

Cockpit gives a person and an AI agent structured local facts about the Mac and controlled operations: thermals/power/display, ports/containers/MCP inventory, and GUI automation readiness. The GUI lives in the menu bar and a cockpit window.

## Design priorities

- Keep Overview, Tune, Scope, and Operate clearly separated but visually coherent.
- Reuse one panel with two chromes: menu-bar popover and cockpit window must not drift.
- Distinguish read-only facts from mutations such as reboot, switching, or tuning.
- Surface Accessibility, Screen Recording, unsupported hardware, and permission states plainly.
- Make live status readable at a glance; keep detailed diagnostics one level deeper.

## Prototype boundaries

Use synthetic machine facts. Never request or display passwords, Keychain values, or real local process secrets. Do not invent cloud, billing, or hosted features. Mutating controls need explicit confirmation language and are never implied by a status card.
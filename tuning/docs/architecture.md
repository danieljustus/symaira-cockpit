# Symaira Cockpit tuning package — Architecture

## Overview

Cockpit is a local macOS tuning tool for humans and AI agents. The CLI, the
MCP server and the app agent (`symcockpit agent --stdio`) are the Rust binary
in `crates/symcockpit`; it reads the Mac's thermal/power/display state and
performs bounded actions. This Swift package holds the GUI side only:

```
SymCockpitMenuBarApp  →  SymCockpitUI  →  SymCockpitCore (AgentSession/AgentClient)
                                       →  SymCockpitHelperKit
```

- The agent/user decides *what* to do.
- The Rust binary reads deterministic environment state and performs bounded actions.
- The transport for agents is local MCP over stdio.

The former Swift `TuneController`, `SymCockpitMCP`, `SymCockpitCLI` and
`symtune` executable were removed in Cockpit 2 wave 2D-3; their behavior is
pinned by the frozen v0.12 oracle (`oracle/`).

## Components

### `SymCockpitCore`

The only target with IOKit access on the Swift side: the `AgentClient` /
`AgentSession` link to the Rust agent, models and formatting for the panel,
the SMC fan-helper pieces (`SMCService`, `FanControlService`, `FanGovernor`,
`SMCWritePolicy`, `SafetyPolicy`), sensors, battery, storage, AI-usage
presentation, HUD layout and the privileged-elevation resolver.

### `SymCockpitHelperKit`

XPC contract, signing requirements and heartbeat watchdog of the optional
privileged fan helper.

### `SymCockpitUI`

The menu-bar panel, HUD and preferences, shared by `SymCockpitMenuBarApp` and
the cockpit GUI (`Sources/SymCockpitApp`). It never constructs a controller;
data comes from agent events and actions are agent commands.

## Capability tiers

Every shipped capability is tagged `core` — it lives in this Apache-2.0 binary;
there is no separate Pro tier for hardware tuning (see
[`docs/commercial-boundary.md`](commercial-boundary.md)). Capabilities that
write to the SMC (`fan.control`, `battery.chargeLimit`) additionally require
root privileges at runtime. `doctor` reports `available` + `tier` per
capability so callers never guess. Honesty rule: unbuilt → `.notImplemented`;
hardware/tier gated → `.unsupported`.

## Why some writes need elevated privileges

- **Extended/EDR brightness**, **sub-minimum dimming**, **built-in brightness**,
  and **color temperature warmth** use on-screen EDR layers, overlay windows, and
  gamma LUTs. These work from the CLI today — no app target needed.
- **Fan control** and **charge limiting** require SMC *writes*, which the kernel
  only allows from a root process. The supported mode is running the CLI with
  `sudo`; the same process clamps through `SafetyPolicy` and restores the
  original SMC values on exit. An optional `symtune-helper` daemon
  (`SMAppService` + XPC) may be added later as a convenience so the main binary
  does not have to run as root — a wrapper around the same core logic, not a
  requirement. SMC *reads* are unprivileged and ship in the core.

## Distribution

Notarized direct download + Homebrew cask. The Mac App Store sandbox forbids SMC
access, DDC, and shipping a global CLI for agents.

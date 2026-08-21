# symaira-tune Architecture

## Overview

`symtune` is a local macOS tuning tool for humans and AI agents. It exposes the
Mac's thermal/power/display state as JSON over a CLI and as MCP tools, and
(incrementally) lets callers adjust brightness, fans, and battery charging.

Design split (mirrors the rest of the Symaira family):

```
symtune (executable)  →  SymTuneMCP  →  SymTuneCore
```

- The agent/user decides *what* to do.
- `symtune` reads deterministic environment state and performs bounded actions.
- The transport for agents is local MCP over stdio.

## Components

### `SymTuneCore`

The only target with logic or IOKit access.

- `TuneController` — facade. CLI and MCP talk to this and nothing else. Holds the
  services, applies `SafetyPolicy`, and owns restore-on-exit bookkeeping.
- `SensorService` — thermal pressure (`ProcessInfo.thermalState`) and, when
  available, detailed temps/fan RPM via `SMCService`.
- `SMCService` — AppleSMC IOKit bridge for sensor reads (die temps, fan RPM;
  unprivileged) and SMC writes (fan speed, charge limiting; requires root).
  `FanControlService` and `ChargeLimitService` implement the two write paths
  behind `SMCWritePolicy` validation, with `SMCRestoreTracker` restoring the
  original SMC values on exit.
- `BatteryService` — reads `AppleSmartBattery` from the IORegistry (unprivileged;
  Intel + Apple Silicon notebooks).
- `DisplayService` — enumerates `NSScreen`s, reports EDR headroom (the signal
  that drives extended/>100% brightness), gets/sets built-in display brightness,
  applies gamma-based color temperature warmth, and resets gamma to neutral.
- `PowerService` — IOKit power assertions (keep-awake), the `caffeinate` analog.
- `SafetyPolicy` — clamping ranges and the thermal-protection guarantee.
- `Models` / `Errors` / `ExitCode` / `Config` / `Version` — DTOs and conventions.

### `SymTuneMCP`

- Thin facade (`TuneMCPServer`) over the shared `SymairaMCP` module from
  `symaira-appkit`: registers the `tools/list` and `tools/call` handlers on
  `MCPServer.withMethodHandler(_:)`, served over `MCPStdioTransport`
  (newline-delimited JSON-RPC, per the MCP spec's stdio framing).
- `initialize`, `tools/list`, `tools/call`, `ping` are owned by `SymairaMCP`.
- One place for tool schemas + argument validation (`TuneToolRegistry`),
  including JSON Schema `minimum`/`maximum` safety bounds.

### `symtune` (CLI)

- Argument routing, JSON emission (`.convertToSnakeCase`, pretty), `serve` wiring,
  and the blocking `awake` loop.

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

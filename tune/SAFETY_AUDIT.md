# symtune Safety Model

This document describes the safety boundaries of the public `symtune` core as it
exists today. It is an implementation-grounded trust document, not a thermal
safety certification, a guarantee for every Mac model, or a promise about future
helper integration.

## Scope and status

`symtune` is a local macOS CLI and stdio MCP server for reading machine state and
applying display/power/fan/battery overrides. The public core currently implements
these write paths:

- built-in display brightness;
- extended/EDR brightness through an on-screen overlay;
- software dimming through an on-screen overlay;
- display warmth through a gamma LUT;
- keep-awake power assertions;
- **fan speed via Apple SMC writes** (requires root);
- **battery charge limiting via Apple SMC writes** (requires root).

Relevant implementation:

- [`SafetyPolicy.swift`](Sources/SymTuneCore/SafetyPolicy.swift) — hard safety ranges and clamp primitive;
- [`SMCWritePolicy.swift`](Sources/SymTuneCore/SMCWritePolicy.swift) — dynamic SMC write validation (fan floor, thermal emergency, AC adapter check);
- [`Config.swift`](Sources/SymTuneCore/Config.swift) — user configuration bounded by hard ranges;
- [`TuneController.swift`](Sources/SymTuneCore/TuneController.swift) — single write facade;
- [`OverrideTracker.swift`](Sources/SymTuneCore/OverrideTracker.swift) — display override capture and restoration;
- [`SMCRestoreTracker.swift`](Sources/SymTuneCore/SMCRestoreTracker.swift) — SMC override capture and restoration;
- [`FanControlService.swift`](Sources/SymTuneCore/FanControlService.swift) — fan mode, target RPM, and auto-restore;
- [`ChargeLimitService.swift`](Sources/SymTuneCore/ChargeLimitService.swift) — platform-specific charge-limit SMC writes;
- [`TuneTools.swift`](Sources/SymTuneMCP/TuneTools.swift) — MCP schemas and write-tool routing;
- [`SMCHelperProtocol.swift`](Sources/SymTuneCore/SMCHelperProtocol.swift) — optional future privileged-helper contract.

## Threat model

The safety model addresses:

1. **Malformed or extreme input** from a user, script, profile, or AI agent.
2. **An over-permissioned local MCP client** invoking a write tool without a
   human in the loop (mitigated by explicit `SYMTUNE_MCP_MODE=read-only` / `[mcp] mode = "read-only"` gating in [`Config.swift`](Sources/SymTuneCore/Config.swift) and [`TuneMCPServer.swift`](Sources/SymTuneMCP/TuneMCPServer.swift)).
3. **Stale process state**, where a temporary override would otherwise remain
   after `symtune` exits.
4. **Unsupported hardware or missing privileges**, where pretending that a
   capability worked would be more dangerous than refusing the request.
5. **SMC writes**, which must not bypass the firmware's thermal control or write
   arbitrary values to hardware.

The model does **not** protect against a user who deliberately grants a hostile
process access to `symtune`, a compromised macOS host, kernel-level malware,
physical hardware faults, `SIGKILL`, a crash before cleanup, or power loss.

## Trust boundaries

### Local process boundary

`symtune` is a local process. It does not provide an authentication or
multi-user authorization layer for its CLI or stdio MCP server. The operating
system user and the process host are therefore part of the trust boundary.

Do not expose `symtune serve` through a network bridge unless that bridge adds
its own authentication, authorization, and audit controls. Stdio is transport,
not authorization.

### MCP boundary

The MCP server exposes read tools and (optionally) write tools. A connected MCP client can
request display changes, load a profile, keep the Mac awake, control fans, set a
charge limit, or call `restore`. Write tools can be completely disabled at server startup via
`SYMTUNE_MCP_MODE=read-only` or `[mcp] mode = "read-only"` in `config.toml`, which filters
write tools out of `tools/list` and rejects direct `tools/call` attempts on write tools.
When write tools are enabled (`SYMTUNE_MCP_MODE=full`, default):

- MCP schemas publish minimum and maximum values for numeric inputs;
- the controller clamps again before applying a write;
- unsupported hardware calls fail instead of being simulated.

The schema is only a client-facing contract. The controller is the enforcement
boundary. MCP transport and JSON-RPC wiring are implemented in
[`TuneMCPServer.swift`](Sources/SymTuneMCP/TuneMCPServer.swift); tool schemas and calls
are in [`TuneTools.swift`](Sources/SymTuneMCP/TuneTools.swift).

### Configuration boundary

`config.toml` and `SYMTUNE_*` variables may change configured limits, but they
cannot widen the hard limits in `SafetyPolicy`. Inverted or invalid ranges fall
back to defaults. Configuration is not a way to disable the safety policy.

### Privilege boundary for SMC writes

Fan and charge-limit commands write to the Apple SMC. The current implementation
performs these writes in the same `symtune` process, which must therefore run as
root (`sudo`). The controller does not silently escalate; without root the SMC
driver returns a permission error that is surfaced to the caller. A future
optional `symtune-helper` daemon may run with elevated privileges and expose the
same operations over XPC, but the helper remains a convenience wrapper around
the same core safety logic.

### Privileged-helper trust boundary

The planned privileged `symtune-helper` daemon (contract in
[`SMCHelperProtocol.swift`](Sources/SymTuneCore/SMCHelperProtocol.swift)) runs
as root, so it must answer one question before serving any request: **who may
call the helper?** `SafetyPolicy` clamping bounds *what* can be written, not
*by whom* — a root XPC service without peer validation accepts a connection from
any local process, making the clamped helper a local privilege-escalation
primitive (any unprivileged app on the machine could pin the fans or inhibit
charging).

Only clients signed by the `symtune` Developer ID team with the expected bundle
identifier may call the helper, and the client must only accept the helper
signed by that same team. The mandatory client-authentication contract requires:

- a code-signing requirement pinned to the `symtune` Developer ID team and
  bundle identifier, set on both directions of the `NSXPCConnection`;
- validation of the peer's **audit token** via `SecCodeCopyGuestWithAttributes`
  — never a PID claimed by the peer, because a PID can be reused by an
  unrelated process after the original exits (PID-reuse race), while the audit
  token is bound to the process the connection was accepted from;
- rejection of peers carrying hardened-runtime escape entitlements
  (`com.apple.security.cs.allow-dyld-environment-variables`,
  `com.apple.security.cs.disable-library-validation`,
  `com.apple.security.cs.allow-unsigned-executable-memory`,
  `com.apple.security.cs.allow-jit`);
- a `SecCodeStatus` of `valid`, `hard`, `kill`, `libraryValidation`, and
  `runtime`.

The helper must refuse the connection when any check fails. These requirements
are blocking acceptance criteria on the helper roadmap item
([`docs/roadmap.md`](docs/roadmap.md)) and are part of the `SMCHelperProtocol`
contract itself.

## Write-path matrix

| Path | CLI / MCP entry point | Effective range | Current status | Restoration |
|---|---|---:|---|---|
| Built-in brightness | `brightness set` / `set_brightness` | `0.0–1.0` | Core, available when the display backend supports it | Original value captured before the first successful override, restored on teardown or `SIGINT`/`SIGTERM` when readable |
| Extended/EDR brightness | `extbright set` / `set_extended_brightness` | `1.0–1.6` | Core, display-dependent | Original system EDR headroom captured best-effort; teardown restores it when available and removes overlays |
| Software dim | `dim set` / `set_dim` | `0.15–1.0` | Core | Overlay is removed during controller/service teardown; `dim reset` removes it explicitly |
| Warmth | `warmth set` / `set_warmth` | `0.0–1.0` | Core, display-dependent | System color-sync settings are restored during `restore` and teardown |
| Keep awake | `awake` / `keep_awake` | Boolean | Core | Power assertion is released when its token is ended; the MCP server holds at most one token |
| Fan control | `fan set` / `set_fan` | `0.0–1.0` fraction | Core, requires root | Original fan mode and target RPM captured before first write; `fan auto` or teardown restores auto mode |
| Charge limit | `battery-limit set` / `set_charge_limit` | `50–100%` | Core, requires root | Original inhibit state captured; `battery-limit clear` or teardown re-enables charging |

All numeric ranges are inclusive. The configured ranges are bounded again by
the constants in `SafetyPolicy`; the table describes the resulting hard limits,
not a promise that every display or Mac exposes every path.

## Guardrails by capability

### Display brightness

`TuneController.applyBuiltinBrightness` clamps through the configured range
(which cannot exceed the hard `SafetyPolicy` range), reads the current value,
and records the original value before applying the new value. A failed hardware
write is logged and propagated to the caller; it is not reported as successful.

### Extended/EDR brightness

EDR brightness is implemented as an on-screen layer, not as a firmware or SMC
write. The multiplier is limited to `1.0–1.6`. Before the first override,
`symtune` captures the system-reported EDR headroom when it can. Cleanup restores
that headroom when available and removes the overlay. If the system value cannot
be read, cleanup still removes the overlay, but an exact pre-existing headroom
value cannot be promised.

### Software dimming

Dimming uses a black, mouse-transparent overlay. The minimum opacity setting is
`0.15`, so the requested output cannot become fully black through this path.
`dim reset` removes all dim overlays and returns the tracked level to `1.0`.

### Warmth

Warmth uses a gamma LUT and is clamped to `0.0–1.0`. Reset uses
`CGDisplayRestoreColorSyncSettings`, returning the display to the system color
settings rather than trying to reconstruct a LUT manually.

### Fan control

`FanControlService` enforces the following before writing to the SMC:

- The requested fraction is clamped to the configured `[fanFractionMin, fanFractionMax]`.
- A soft floor (`SafetyPolicy.fanSpeedFloor`, default 0.15) prevents the user from
  requesting a completely silent fan.
- The target RPM is floored at the firmware-reported minimum `F{n}Mn`, so the
  firmware's thermal floor is never violated.
- Manual mode writes are rejected when any die sensor exceeds the thermal
  emergency threshold (`SafetyPolicy.thermalOverrideCelsius`, default 90 °C).
- On Apple Silicon, `Ftst` is unlocked before manual mode and cleared on
  restore; the manual-mode write is retried with exponential backoff and verified.
- On Intel, the original `FS!` bitmask is saved and restored exactly.

The firmware's own thermal protection still applies: on Apple Silicon the SMC
will override the manual target if the die temperature reaches a critical level.

### Charge limit

`ChargeLimitService` enforces the following:

- The requested percent is clamped to `[chargeLimitMin, chargeLimitMax]`.
- Charging is only inhibited when the Mac is on AC power (`externalConnected`).
- The correct SMC key is probed at runtime: `CHTE` (Apple Silicon, newer firmware),
  `CH0B`/`CH0C` (Apple Silicon, older firmware), or `CHLC` (Intel).
- The original inhibit state is captured before the first write and restored on
  teardown or `battery-limit clear`.

On Apple Silicon the inhibit state is volatile and resets on sleep; users should
re-apply the limit after sleep. On Intel, `CHLC` persists until cleared.

## Restore and failure behavior

`OverrideTracker` and `SMCRestoreTracker` register handlers for `SIGINT` and
`SIGTERM` (via the controller's shared signal handling), restore tracked
overrides, and exit. Normal object destruction also removes tracked overrides,
overlays, and SMC state.

The cleanup guarantee is therefore best-effort and applies to normal teardown
and the handled termination signals. It cannot cover `SIGKILL`, kernel panic,
process crash before cleanup, forced power-off, or hardware/OS failures during
restoration.

### Persisted restore (crash-safe path)

To close that gap, `SMCRestoreTracker` writes the captured SMC originals (fan
mode, target RPM, Intel `FS!` bitmask, charge-inhibit state) to a `0600` JSON
file in the state directory (`~/.local/share/symtune/smc-restore.json`, owner =
invoking user even under `sudo`) at the moment they are captured — before any
write is applied. This inverts the restore from "on shutdown" to "on next
start", which is the only point at which a process is guaranteed to be alive:

- A clean restore (normal exit, `SIGINT`/`SIGTERM`, `symtune restore`) removes
  the file.
- A killed process leaves the file behind; the next CLI invocation or app
  launch consumes it at startup (applies the recorded originals to the SMC,
  then deletes it) before any new override is applied.
- The file records the architecture and charge-limit key family alongside the
  values. A file from a different architecture or with a key family the current
  firmware no longer exposes is discarded, never applied; charge values are
  skipped on key-family mismatch.
- Unreadable/corrupt files are discarded, never applied.

The in-memory restore path is unchanged; the file is advisory and additive.

There is one current semantic limitation that callers must know:
`TuneController.restoreAll()` restores the tracker-backed brightness, warmth, EDR,
fan, and charge-limit state, but does not currently call `resetDim()`. Use
`dim reset` when the process must remain running and the dim overlay should be
removed immediately. The dim overlay is still removed when the controller/service
is torn down.

## What `symtune` will never do in the public core

The current core does not:

- accept an unbounded numeric value and pass it directly to hardware;
- claim that an unavailable or unimplemented capability succeeded;
- disable, replace, or silence firmware thermal protection;
- force battery discharge (the `CH0I` key is not used);
- expose a network listener as part of `symtune serve`;
- store credentials, billing data, tenants, or cloud control-plane state;
- provide a guarantee that cleanup survives crashes, `SIGKILL`, or power loss.

A future helper or app must not weaken these boundaries. New write capabilities
require a corresponding controller path, hard range, tests, capability report,
MCP schema, and documentation update.

## Commercial boundary

There is no separate "Pro" repository or feature gate for `symtune`. All
hardware-tuning capabilities are in the open Apache-2.0 core. See
[`docs/commercial-boundary.md`](docs/commercial-boundary.md).

## Evidence and verification

The safety claims in this document are grounded in the current source and tests,
including:

- `SafetyPolicyTests` for clamping and the dim floor;
- `WriteSurfaceTests` for controller routing;
- `FanControlServiceTests` for fan mode, target RPM, and safety floor;
- `ChargeLimitServiceTests` for SMC key probing and inhibit/allow logic;
- `SMCRestoreTrackerTests` for SMC restore-on-exit tracking;
- `MCPServerToolSchemaTests` for published numeric bounds;
- `MCPServerToolCallTests` for MCP tool routing and restore/dim calls;
- `SMCServiceTests` for bounded test-double SMC writes and unavailable hardware;
- `HardwareBackendIntegrationTests` for headless hardware-backend behavior.

Run the repository's standard checks before publishing changes:

```bash
swift build
swift test
swift run -q symtune doctor
```

This document must be updated whenever a new write path, helper integration,
restore behavior, or MCP tool changes the actual trust boundary.

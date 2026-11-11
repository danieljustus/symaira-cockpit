# Hardware Compatibility Matrix

Which symtune features work on which Mac. Capabilities vary by processor
generation (Apple Silicon vs Intel), chassis design (fanless vs active cooling),
and display hardware (standard vs XDR/EDR). Run `symtune doctor` to see exactly
what's available on your machine.

## Feature Support Matrix

| Feature | Apple Silicon (M1+) | Intel Mac | Notes |
|---|---|---|---|
| `sensors.thermalPressure` | All | All | Coarse thermal level from `ProcessInfo` (nominal...critical). No special permissions needed. |
| `sensors.smc` | v0.1 | v0.1 | Detailed die temperatures and fan RPM via AppleSMC IOKit. Read-only, unprivileged. Implemented for both architectures, but SMC keys differ (see below). |
| `battery.read` | Notebooks only | Notebooks only | `AppleSmartBattery` health readout from IORegistry. Works the same on both architectures. |
| `display.edr.read` | XDR/EDR displays only | XDR/EDR displays only | Per-display EDR headroom detection. Requires an HDR-capable panel (e.g. Liquid Retina XDR). |
| `display.brightness.extended.set` | v0.1 (EDR displays) | v0.1 (EDR displays) | Extended (>100%) brightness via on-screen EDR layer. Clamped 1.0-1.6 by `SafetyPolicy`. CLI works today; the menu-bar UI is the v0.2 target. |
| `display.dim.set` | All displays | All displays | Sub-minimum software dim overlay. Clamped >= 0.15 by `SafetyPolicy`. Ships in v0.1 (CLI; menu-bar UI in v0.2). |
| `display.brightness.set` | Built-in displays (limitations) | Built-in displays | Hardware brightness get/set for the built-in panel. On Apple Silicon, the control path differs from Intel (CoreDisplay vs DisplayServices). Ships in v0.1. |
| `power.keepAwake` | All | All | Prevent idle sleep via IOKit power assertion. Works on every Mac. Ships in v0.1. |
| `fan.control` | Macs with fans | Macs with fans | Core tier. SMC writes require root — run with `sudo`. Not available on fanless models (MacBook Air). |
| `battery.chargeLimit` | Apple Silicon notebooks | Some Intel notebooks | Core tier. SMC writes require root — run with `sudo`. The IOKit/SMC keys differ between architectures. |
| `power.draw.read` | Total (`PSTR`, else battery `SystemLoad`) + DC-in rail | Total (`PSTR`) + DC-in rail | `system_watts` is the whole Mac's consumption (SMC `PSTR`, falling back to `AppleSmartBattery` `PowerTelemetryData.SystemLoad` on laptops) and is valid on battery. `volts`/`amps`/`watts` (also `adapter_watts`) are adapter DC-in input only (`VD0R`/`ID0R`/`PDTR`, `PD0R` when `PDTR` reads 0) and are about 0 on battery. Unprivileged, read-only. Each field is absent on Macs that do not expose its key — `doctor` reports which values are readable. |
| `gpu.utilization.read` | All Macs with an `IOAccelerator` | All Macs with an `IOAccelerator` | Device utilization percent from the IORegistry's `PerformanceStatistics` (`Device Utilization %`), as `gpu.utilization_percent` in `metrics` / `get_system_metrics`. Unprivileged. The `gpu` block is absent when the registry publishes no value. |
| `gpu.processes.read` | Apple Silicon (verified on M4 Pro) | Not verified | Per-process GPU share from the `AppUsage` / `accumulatedGPUTime` counters of the accelerator's user clients (`processes --sort gpu`), rated between two samples. Unprivileged. The first sample reports no percentage ("measuring"). Falls back to root-only `powermetrics` when the registry exposes no `AppUsage`. |

### Tier and status legend

- **Core tier**. Ships in the Apache-2.0 licensed binary. No extra installation.
  Every shipped capability is core tier; there is no separate Pro tier for
  hardware tuning (see [`docs/commercial-boundary.md`](commercial-boundary.md)).
  Capabilities that write to the SMC (`fan.control`, `battery.chargeLimit`)
  require root privileges — run the CLI with `sudo`.
- **v0.1**. Available now.
- **v0.2**. Planned for the next release cycle (app target needed for display
  overrides).
- **unsupported**. `symtune doctor` reports the capability as `available:
  false` with the reason. The CLI and MCP hand them as honest errors, not
  crashes.

## Apple Silicon vs Intel

While the high-level feature set is the same across architectures, the
low-level implementation paths differ. Here is what is different under the
hood.

### SMC temperature keys

The AppleSMC IOKit service exists on both Intel and Apple Silicon Macs, but
the key namespace for temperature sensors is not identical.

- **Intel**: Die temperatures use well-known multi-character keys (`TC0P` for
  CPU proximity, `TC0D` for CPU die, `TG0D` for GPU die, `TB0T` for
  battery). These are documented in the community SMC key reference.
- **Apple Silicon**: The system-on-chip integrates CPU, GPU, Neural Engine,
  and memory controller on one die. The SMC key names differ, and the set of
  exposed sensors is not a superset of the Intel keys. Every generation
  shares two authoritative peak sensors — `TCMz` (CPU die hotspot) and
  `TRDX` (GPU die hotspot, where the SoC has a GPU) — but the remaining
  sensor namespaces (E-core cluster, SoC) have shifted between chip
  generations.

`SMCService` (v0.2) keeps a *candidate* table per chip generation, detected
from `machdep.cpu.brand_string`. The reported temperatures are the
intersection of the generation's candidate row and the keys the host actually
exposes through index-based enumeration (the `#KEY` count probe plus a
per-index key lookup). Absent keys are omitted — never reported as zero or
unknown. On macOS builds where the raw AppleSMC user client is restricted,
enumeration is unavailable; `symtune sensors` then falls back to the
candidate row and says so in `notes` instead of assuming enumeration worked.

#### Apple Silicon per-generation candidate keys

| Generation | E-core cluster keys | Notes |
|---|---|---|
| M1 | — | `Tp01`–`Tp12` P-core candidates, `TG0P` GPU die, `TM0P` memory proximity, `Ts0S` SoC, `Ta0P` ambient; enumeration trims rows to the cores present |
| M2 | `Te04`–`Te06` | Adds `TCMb` (CPU die core max) and `TCHP` (CPU/charger proximity), verified on M2 (MacMonitor SENSORS.md) |
| M3 | `Te05`/`Te0L`/`Te0P`/`Te0S` | E-core namespace shifted from M2 (prior art) |
| M4 | `Te05`/`Te0S`/`Te09`/`Te0H` | M4 E-core row (prior art; could not be re-verified on macOS builds that block unprivileged AppleSMC reads — the enumeration intersection trims any row a host does not expose) |
| unknown | union of all rows | Fallback for undetected/future chips (e.g. M5); trimmed by enumeration |

Both architectures expose fan RPM keys when a fan is present: `F0Ac` on Intel,
and equivalent keys on Apple Silicon.

### Fan control

- **Intel**: Fan control uses SMC write keys (`F0Tg`, `F1Tg` for target speed,
  `F0Md`/`F1Md` for manual mode). The community has reverse-engineered these
  extensively.
- **Apple Silicon**: The fan control keys are different. While the concept
  (manual override with a firmware floor) is the same, the exact key names and
  the way minimum speeds are enforced diverged. `FanControlService` abstracts
  both behind a single interface.

The optional Cool target (a maximum *average* CPU/GPU cluster temperature,
50–85 °C) averages only cluster rows that read back plausibly: Apple Silicon
`Tp01`–`Tp12` and `Te*` (CPU), `Tg*`/`TG0P`/`TRDX` (GPU — `TRDX` is the GPU's
only reading on Apple Silicon), Intel `TC#C`/`TCXC`. The CPU die hotspot `TCMz`
stands in only when a Mac exposes no CPU core/cluster row; `TCMb` (core max), proximity (`TCHP`, `TC0P`, `TM0P`), ambient and `Ts0S` are
never averaged. On an M4 Pro `Tp01`–`Tp09` partly read 0–8 °C and are dropped
by the plausibility gate, so the average there comes from the remaining rows.
The target can only raise the fan fraction above the normal Cool curve.

On both architectures, `SafetyPolicy` guarantees that fan control can only
*raise* the speed above the firmware's automatic curve, never silence it. The
firmware thermal protection always takes precedence.

### Battery charge limiting

- **Intel**: Charge limit is typically set through the SMC `BCLM` key (as a
  percentage) or via IOKit properties on newer models.
- **Apple Silicon**: Charge limit is controlled through IOKit properties on
  the `AppleSmartBattery` service. The mechanism differs enough that separate
  code paths are needed in `ChargeLimitService`.

`battery.read` (charge percentage, cycle count, health) works identically on
both architectures. The difference is only in the *write* path for setting the
target.

### Brightness control

- **Built-in display**: On Intel Macs, brightness is read and written through
  `DisplayServices` or CoreDisplay private APIs. On Apple Silicon, the same
  goal is achieved through CoreDisplay, but some internal function names and
  behaviours differ. symtune's `DisplayService` (v0.1) handles both paths.
- **External monitors**: DDC/CI brightness control is not implemented; it is
  being evaluated. It works over IOKit I2C on both architectures.
- **EDR/extended brightness**: Uses an AppKit on-screen EDR layer. This is an
  app-context feature (requires a GUI process) and is architecture-agnostic.

## Fanless Macs (MacBook Air)

Every MacBook Air generation (M1, M2, M3, M4) lacks an active cooling fan.
This has specific implications for symtune.

| Area | What changes |
|---|---|
| `fan.control` | Reports `unsupported`. There is no fan hardware to control. `doctor` shows `available: false, tier: core` with a clear message. |
| `sensors.smc` | No fan RPM to report, but die temperature sensors are still available. The RPM field in the sensor report is absent or zero. |
| `sensors.thermalPressure` | Works normally. Fanless Macs rely entirely on passive cooling and throttling under sustained load. |
| `display.*` | All display features work the same as on any other Mac with the same display hardware. |
| `power.keepAwake` | Works normally. |
| `battery.*` | Works normally. |

Thermal behaviour note: fanless Macs manage heat through the chassis and
aluminium enclosure. Under sustained load, `ProcessInfo.thermalState` may
reach `serious` or `critical` sooner than on a fan-cooled Mac. This is normal
and expected. symtune reports the state honestly without interfering.

## EDR-Capable Displays

EDR (Extended Dynamic Range) is the macOS mechanism that enables brightness
above the standard 100% SDR reference level. It is the signal that tells
symtune whether extended brightness controls will work on a given display.

### Which displays have EDR

| Display type | EDR capable | Peak brightness |
|---|---|---|
| MacBook Pro 14" Liquid Retina XDR (2021+) | Yes | 1600 nit (peak), 1000 nit (sustained XDR) |
| MacBook Pro 16" Liquid Retina XDR (2021+) | Yes | 1600 nit (peak), 1000 nit (sustained XDR) |
| MacBook Air Liquid Retina (any) | No | 500 nit |
| MacBook Pro 13" (Intel) | No | 500 nit |
| iMac (standard) | No | Varies (typically 500 nit) |
| iMac Pro | No (standard SDR) | 500 nit |
| Apple Pro Display XDR | Yes | 1600 nit (peak) |
| Apple Studio Display | No | 600 nit |
| External HDR-capable monitors | Varies | Varies by model |

EDR capability is not the same as HDR video playback. A display may support
HDR video (via AVPlayer or QuickTime) without having EDR headroom for the
full GUI. symtune checks
`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`. If this
value is greater than 1.0, the display can show content brighter than the SDR
white point.

### How to check EDR headroom

```
symtune displays
```

The output includes `max_edr_headroom` (current available headroom) and
`potential_edr_headroom` (maximum the display can sustain). A `potential_edr_headroom`
of 1.0 means no extended range is available on that display.

### Extended brightness requirements

- The display must be EDR-capable (`potential_edr_headroom > 1.0`).
- Extended brightness (`display.brightness.extended.set`) uses an on-screen
  EDR layer. Ships in v0.1 — the CLI runs in a GUI session by default on
  macOS and applies the layer via `EDROverlayService` (see
  `Sources/SymCockpitCore/EDROverlayService.swift`).
- The multiplier is clamped to 1.0-1.6 by `SafetyPolicy`. Values above 1.0
  push the display brighter than 100% SDR; 1.6 is the ceiling.
- `display.dim.set` (the software dim overlay) works on *any* display, EDR or
  not. It is a separate mechanism that does not depend on display hardware
  capability.

## Permission Requirements

### Read features (no special permissions)

| Feature | Permissions needed |
|---|---|
| `sensors.thermalPressure` | None |
| `sensors.smc` (read) | None (unprivileged IOKit access) |
| `battery.read` | None (unprivileged IORegistry access) |
| `power.draw.read` | None (unprivileged SMC read) |
| `display.edr.read` | None (AppKit, GUI session) |
| `power.keepAwake` | None (IOKit power assertion) |

These work from the command line and from the MCP server. The binary does not
need root or any entitlement beyond the standard AppKit sandbox exemption.

### Write features (varying levels)

| Feature | Requirement |
|---|---|
| `display.dim.set` | GUI session, no elevated privileges (v0.1). |
| `display.brightness.extended.set` | GUI session, no elevated privileges (v0.1). |
| `display.brightness.set` | GUI session (v0.1). May need accessibility permissions on some macOS versions. |
| `fan.control` | Core tier. Root privileges for the SMC write — run with `sudo`. |
| `battery.chargeLimit` | Core tier. Root privileges for the SMC write — run with `sudo`. |
| DDC/CI external brightness | Not implemented. Being evaluated. |

### Optional privileged fan helper

By default SMC writes run in the `symcockpit` process itself, which therefore
needs root: `sudo` on the command line, `osascript … with administrator
privileges` from the GUI (against a root-owned copy of the CLI only).

The signed and notarized `Symaira Cockpit.app` can additionally ship an
**opt-in** `SMAppService` daemon (issue #405). It is part of this Apache-2.0
repository, not a separate tier.

| Aspect | Behaviour |
|---|---|
| Identity | `com.symaira.symtune-helper` (grandfathered): launchd label, Mach service and code-signing identifier. Executable `Contents/Library/LaunchServices/com.symaira.symtune-helper`, plist `Contents/Library/LaunchDaemons/com.symaira.symtune-helper.plist`. |
| Opt-in | Off by default. Preference `com.symaira.symtune.fanHelper.enabled`, toggled in Preferences → *Privileged fan helper*. With it off, fan control is unchanged (`osascript`). |
| Registration | `SMAppService.daemon(plistName:)`. `requiresApproval` is shown as such, with a shortcut to System Settings → Login Items & Extensions; until approved, the `osascript` path stays in use. |
| Signed builds only | Unsigned, ad-hoc or self-signed builds never register and never connect. The decision is made from the app's own signature (Developer ID chain, team identifier, `com.symaira.cockpit` identifier). |
| XPC authentication | `NSXPCConnection.setCodeSigningRequirement` on both sides. The helper accepts only `identifier "com.symaira.cockpit"`; the app accepts only `identifier "com.symaira.symtune-helper"`; both on `anchor apple generic`, the Developer ID leaf/CA OIDs and `certificate leaf[subject.OU]` equal to the team id. That team id is **embedded at build time** (`EmbeddedTeamIdentifier`, written by `scripts/build-app.sh` from `EXPECTED_TEAM_ID`, which `release.yml` reads from the Developer ID certificate) and must also equal the team of the running binary's own signature, on both sides; a build without an embedded team id never registers and never serves the helper. Peers with `allow-dyld-environment-variables`, `disable-library-validation`, `allow-unsigned-executable-memory` or `allow-jit` are refused. The app also checks the helper embedded in its bundle against the same requirement before connecting. |
| Wire surface | `startGovernor(profile:)` with one of `system`/`comfort`/`performance`, `heartbeat`, `stopGovernor`, `status`. No raw RPM or SMC key can be expressed; every write still goes through `FanGovernor` and `SMCWritePolicy`/`SafetyPolicy`. Charge-limit writes are not part of it. |
| Bundle trust | `register()` refuses when the app bundle or the helper executable is group/other-writable, a symlink, or owned by neither the current user nor root (`BundleTrustCheck`). The check walks every path component from the bundle root to the helper (`Contents`, `Contents/Library`, `Contents/Library/LaunchServices`, the helper) and runs again before each governor start. Remaining assumption: an app installed by dragging it into `/Applications` is user-owned, so malware running as that user can modify the bundle, and a modified helper would run as root once registered. The pinned team only prevents a swapped helper from pairing with the app over XPC; it does not prevent it from being executed. macOS App Management protection is the guard against other apps modifying the bundle. `sudo chown -R root:wheel '/Applications/Symaira Cockpit.app'` closes the gap. Trust policy unchanged (owner decision pending). Unverified on hardware. |
| Stored profile | The helper reads no files. The app reconciles `fan-profile.json` with it on every heartbeat (about 2 s): `system` stops the helper, a different governed position retargets it. A CLI/MCP `fan profile system` therefore still ends helper-driven governing. |
| Limits | The helper uses the `SafetyPolicy` defaults only; `SYMTUNE_FAN_*` and user config do not loosen (or tighten) them in a root process. |
| Start semantics | `startGovernor` replies once the request is accepted, before the first tick. An immediate governor failure (SMC unavailable, no thermal headroom) shows up as the helper no longer governing: the next heartbeat reports it, the app restarts the governor up to three times per user action, then stops and the UI shows it as not in effect. |
| Governor | The existing `FanGovernor` loop, including its bounded failure policy (missing temperature, SMC not holding the state): on giving up it restores the captured fan state and the helper reports `failed`. |
| Dead-man switch | The app pings every 2 s. No ping for more than 7 s (checked every 1 s), an invalidated/interrupted connection, or SIGTERM makes the governor unwind through its own restore, returning the fans to the state it found. |
| Removal | Preferences toggle off (restores, unregisters). Manual: delete the app and remove its Login Items entry, or `sudo launchctl bootout system/com.symaira.symtune-helper`. |

Hardware-validated behaviour (a signed registration on a real Mac, rejection of
a wrongly signed peer, restore after killing the app) is still to be recorded
here once measured; the unit tests cover the decision logic with fakes only.

`symtune permissions` reports the current permission and SMC write status.

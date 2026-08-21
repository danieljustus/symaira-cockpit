# Agent Instructions — symaira-tune

Native macOS tuning tool (Swift 6 toolchain, AppKit/IOKit). CLI **and** MCP
server: read the Mac's thermal/power/display state, and (incrementally) tune
brightness, fans, and battery charging. Public repo, Apache-2.0 licensed. Part of the
Symaira family — see `../AGENTS.md` / `../ECOSYSTEM.md` for cross-repo
conventions and `docs/commercial-boundary.md` for the public/pro boundary.

## Build & Test

```bash
swift build                # all targets
swift test                 # unit tests (no GUI / no hardware writes required)
make coverage              # line/region coverage for the library targets
swift run -q symtune doctor
```

**Coverage scope:** `make coverage` reports `SymTuneCore` and `SymTuneMCP` only.
The `symtune` executable is *not* instrumented — its tests spawn the built
binary, so `Sources/symtune/*` is absent from the report rather than counted
as uncovered. Logic that should be measured therefore belongs in a library
target (see `Sources/SymTuneCore/ProcessListingPresentation.swift` for the
pattern: the CLI keeps argument plumbing and I/O, the core owns the
decisions); the same applies to `SymTuneApp`, which has no test target at
all.

Local toolchain note: if the Command Line Tools `swift` is broken (dyld errors),
build with the Xcode(-beta) toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
```

## Module Layout (SPM, dependency direction enforced by target deps)

```
symtune (executable)  →  SymTuneMCP  →  SymTuneCore
```

- `SymTuneCore` — all logic. Services (`SensorService`, `BatteryService`,
  `DisplayService`, `PowerService`, `SMCService`), models, config, errors, and
  `SafetyPolicy`. No MCP/CLI concerns here. Only target allowed to touch IOKit.
- `SymTuneMCP` — stdio JSON-RPC/MCP transport. Talks to `TuneController` only.
- `symtune` — thin CLI: arg routing, JSON output, `serve` wiring.

`TuneController` is the single facade. CLI and MCP never call services directly.

## Hard Rules

- **Safety first**: every write path (brightness, dim, fan, charge limit) MUST
  clamp through `SafetyPolicy` before applying, and MUST never disable firmware
  thermal protection. The controller is responsible for *restore-on-exit*: any
  overridden value resets to the system default when the process ends.
- **One owner for the gamma table**: colour warmth and extended brightness both
  write the display's gamma LUT. All writes go through `DisplayGammaController`,
  which composes both inputs onto the ramp captured *before* any override — never
  call `CGSetDisplayTransferByTable` from anywhere else, and never rebuild a ramp
  from scratch (that discards the display's calibration).
- **Extended brightness needs both halves**: an on-screen EDR layer that is
  actually rendered and presented (so macOS grants headroom) *and* a gamma boost
  clamped to the granted headroom. Report `requested` vs `effective` rather than
  assuming a request took effect.
- **Honest capabilities**: never pretend a feature works. Unbuilt features throw
  `.notImplemented`; hardware/tier-gated ones throw `.unsupported`. `doctor`
  reports the truth per capability (`available` + `tier`).
- **Public/pro boundary**: no billing/tenant/cloud code here. SMC-write features
  (fan, charge limit) belong behind the privileged Pro helper — implement the
  core capability here first, then let the private repo consume it.
- **Zero stdout pollution in `serve`**: stdout carries only newline-delimited
  JSON-RPC frames (MCP spec stdio framing, via `SymairaMCP`). All logs go to stderr.
- **No third-party SPM dependencies** without a strong reason — system frameworks
  only, so the binary stays trivial to build, sign, and notarize.
- **JSON is snake_case**: encoders use `.convertToSnakeCase`. Keep Swift
  properties camelCase.

## Conventions (ecosystem)

- Binary: `symtune`. Paths: `~/.config/symtune/`, `~/.cache/symtune/`,
  `~/.local/share/symtune/` (see `ConfigPaths`). Env prefix: `SYMTUNE_*`.
- Exit codes: `0` ok · `1` error · `2` usage/config · `3` permission ·
  `4` unsupported/not-implemented (`ExitCode`).
- Distribution: notarized Direct/Homebrew cask (NOT the Mac App Store — fan/SMC
  and a global CLI are incompatible with the App Store sandbox).

## Roadmap pointers

`docs/roadmap.md` is the source of truth for what's built vs planned. v0.1 =
reads + keep-awake + MCP scaffold. v0.2 = standalone menu-bar app + EDR/extended
brightness + dim overlay + SMC sensor reads. v0.3 = fan control and battery
charge limiting shipped directly in the open Apache-2.0 core (no separate Pro
tier or privileged helper required); an optional `symtune-helper` daemon remains
a future convenience, not a gate. The package already builds in Swift 6 language
mode (`swiftLanguageModes: [.v6]` in `Package.swift`).

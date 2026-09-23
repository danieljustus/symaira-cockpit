# Symaira Cockpit

> **Tune-only product:** Symaira Cockpit provides macOS hardware/system tuning. The former operate and scope capabilities now live in Symaira Brain as optional modules; legacy `symcockpit operate` and `symcockpit scope` commands are removed. See [PB-2026-09-09](docs/product-boundaries.md).

**One command for your Mac: monitor and tune its hardware and system.**

`symcockpit` is a native macOS CLI and menu-bar app for thermals, power,
display, battery, fans and system metrics. Tune commands speak JSON and the
Tune MCP server exposes the same capabilities to AI agents.

[![CI](https://github.com/danieljustus/symaira-cockpit/actions/workflows/ci.yml/badge.svg)](https://github.com/danieljustus/symaira-cockpit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/danieljustus/symaira-cockpit?label=release)](https://github.com/danieljustus/symaira-cockpit/releases)
[![Coverage](https://img.shields.io/badge/coverage-CI%20tracked-informational)](https://github.com/danieljustus/symaira-cockpit/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/danieljustus/symaira-cockpit)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

![Symaira Cockpit](docs/assets/social-preview.png)

**Status:** Active development — v0.7.0 released; see the [release history](https://github.com/danieljustus/symaira-cockpit/releases).

## Why Cockpit

The facts you constantly need while developing on a Mac are scattered across a
dozen places: Activity Monitor, `lsof`, Docker Desktop, System Settings,
`pmset`, and the harness registrations managed by symbrain. Symaira Cockpit
pulls the local machine facts into **one binary** with **one output format**:

- **Structured, not scrapeable.** Every command answers in JSON with stable
  field names. No parsing human-readable output, no `awk`.
- **Local, not cloud.** No telemetry, no account, no network access beyond the
  optional update check. What your Mac knows stays on your Mac.
- **Built for agents.** Tune runs as an MCP server over stdio on demand —
  the capabilities you have on the shell become tools for your AI assistant.
- **Native and fast.** Swift 6, straight against IOKit, Accessibility and
  ScreenCaptureKit. One universal binary, no runtime, no dependencies.

## Install

```bash
brew install danieljustus/tap/symcockpit
```

Or grab the universal binary (`arm64` + `x86_64`) from
[Releases](https://github.com/danieljustus/symaira-cockpit/releases) and drop it
into `/usr/local/bin`.

> The CLI binary is neither signed nor notarized. Installed via Homebrew,
> Gatekeeper's quarantine does not apply; after a manual download you need to
> clear it once (`xattr -d com.apple.quarantine ./symcockpit`).

### Fan control from the GUI needs a root-owned install

Changing fan speed from the menu bar app runs `symcockpit` as root behind
macOS's administrator prompt. The app therefore refuses to elevate a binary
that anything other than root can replace, and names the exact reason when it
does:

```
refusing to run /opt/homebrew/bin/symcockpit as an administrator: it is owned
by daniel, not root. … Install it in a root-owned location such as
/usr/local/bin.
```

Homebrew's prefix does not qualify on Apple Silicon: `/opt/homebrew` is owned
by the installing user and `/opt/homebrew/bin` is group-writable, so anyone who
can write there could have their own binary authenticated into root by your
password prompt. The same applies to `~/.symaira/bin`.

To use fan control from the GUI, install the binary somewhere only root can
write:

```bash
sudo install -o root -g wheel -m 755 "$(brew --prefix)/bin/symcockpit" /usr/local/bin/symcockpit
```

The app prefers this copy for elevation and keeps using the Homebrew one for
everything else. `brew upgrade` does not touch `/usr/local/bin`, so repeat the
command after every upgrade — otherwise fan control silently keeps driving the
older CLI while the rest of the app has moved on.

The CLI, Tune MCP server, and reading Tune's
sensors — works from any install location. Only elevation is restricted, and
`sudo symcockpit tune fan set …` from a terminal is unaffected, because there
you name the binary yourself.

## Quick start

```console
$ symcockpit sensors
{ "thermal_pressure": "nominal", "fans": [ { "rpm": 1980 } ], "smc_supported": true }

$ symcockpit brightness set 0.5
```

## The GUI

The Tune controls, in a window — for the moments a glance beats a command.

```bash
brew install --cask danieljustus/tap/symcockpit
```

installs the signed and notarized menu bar app from the releases page — or grab
the `Symaira-Cockpit-*.dmg` directly from
[Releases](https://github.com/danieljustus/symaira-cockpit/releases).

```bash
make build-app                       # builds build/app/Symaira Cockpit.app
make run-app                         # …and launches it
```

Symaira Cockpit lives in the menu bar. The status item is Tune's: the live
readout you configure in Preferences, with the full control panel one click
away. Right-click it for the cockpit window, which adds

- **Overview** — a tune-only landing page,
- **Tune** — the same control panel the menu bar shows, off the same model,
  plus per-metric switches for what the status item displays.

The Tune section's **Menu bar** card is the quick way to change the status
item: one switch per metric for *Monitor* (sample it) and one for *Menu bar*
(show it), with a live preview of the result. Changes hit the menu bar
immediately and are written to `config.toml`, so they survive a relaunch.

The Display card's **Brightness keys** row picks who answers F1 and F2:
**Standard** leaves them to macOS, **SymCockpit** consumes them before macOS
sees them, sets the built-in display's brightness itself, and draws its own HUD
— the same sixteen steps, with Shift+Option for quarter steps. macOS is the
default; the takeover needs an Accessibility grant, and the row says so and
offers the way to it instead of silently doing nothing. Volume and media keys
are never touched, a focused password field hands the keys straight back, and
switching to Standard removes the interception immediately.

The same card carries **Show in**, which picks *where* the readout appears —
the menu bar or the notch, one at a time rather than both at once. On a MacBook
with a camera cutout, **Notch** draws the readout around the notch and hides
the status item while it runs. It opens in two steps rather than one: the
pointer reaching it widens the shoulders for a readout or two more, and a click
unfolds the full card — every readout you placed there, plus a way into the
panel or the window. A second click, or moving away, puts it back. Dragged, it
resists and stretches for a moment before it comes off the bezel, and springs
back if you let go near nothing.

**HUD content** below it decides what is on the HUD: per readout, whether it
appears, which side it sits on, and how far the HUD has to be open before it
does. It applies as you change it. The menu bar is the default, the choice explains itself instead
of appearing when the display has no cutout, and a display without one always
gets the status item back, so the app is never left with nothing on screen. The
HUD stays put across spaces and over full-screen apps, and it never takes
focus: clicking it does not pull the app in front of what you were working in.

`⌘1`–`⌘2` switch sections and `⌘,` opens preferences.

Nothing in the window has its own logic: every number comes from the same core
services the CLI calls, so the window and the shell cannot disagree. The GUI reads and configures Tune settings through the same core services as the CLI.

> macOS keys permissions and Keychain access to the binary, so the app asks for
> its own grants the first time you use those features — separately from the
> CLI, even on the same Mac.

## Commands

Direct `symcockpit` commands expose thermals, power, battery, display, fan,
brightness, profiles, diagnostics and the Tune MCP server. The old
`symcockpit tune <command>` spelling prints a warning to stderr and remains
supported through v0.9 (the next two minor releases, v0.8 and v0.9); migrate
clients to the direct spelling before its planned removal in v0.10.

```text
symcockpit doctor
symcockpit sensors
symcockpit brightness set 0.5
symcockpit serve
```

## MCP / Agent integration

Tune speaks the Model Context Protocol over stdio. Add the Tune server to an
agent configuration:

```json
{
  "mcpServers": {
    "cockpit-tune": { "command": "symcockpit", "args": ["serve"] }
  }
}
```

In `serve`, `stdout` carries JSON-RPC and nothing else; logs and
diagnostics go to `stderr`.

## Permissions and safety

Cockpit asks only for what Tune needs:

| Capability | Requires |
| :--- | :--- |
| Sensors, battery, metrics, brightness | nothing |
| Fans, charge limit | `sudo` (SMC write) |

Every write action is recorded in local history and restored safely on normal
exit.

## Output contract

- **JSON everywhere.** Snake-case fields, stable keys, `--json` wherever a
  human-readable variant exists. Streams (`watch`) emit NDJSON.
- **Exit codes:** `0` success · `1` error · `2` usage/config · `3` missing
  permission · `4` unsupported on this system.
- **XDG paths:** config under `~/.config/`, cache under `~/.cache/`, data under
  `~/.local/share/`.

```bash
symcockpit version --json
```

## Requirements

- macOS 26 or newer, Apple Silicon or Intel
- Fan and charge-limit control: access to the Apple SMC — not every model and
  not every macOS build permits it, and `tune sensors` will tell you

Unsupported capabilities report exit code `4` cleanly instead of guessing.

## Build from source

```bash
git clone https://github.com/danieljustus/symaira-cockpit.git
cd symaira-cockpit
make build      # Debug build of Tune and history
make test       # Test suite
make build-app  # The GUI bundle (build/app/Symaira Cockpit.app)
swift build -c release --arch arm64 --arch x86_64
```

The repository is an SPM workspace: `Sources/symcockpit/` is the dispatcher,
`Sources/SymCockpitApp/` the GUI,
and [`tune/`](tune/) are
a standalone package with its own test suite. Contributor details live in
[AGENTS.md](AGENTS.md).

> The app targets and the tests need the Xcode toolchain:
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build`

## Contributing

Issues and pull requests are welcome. For anything larger than a fix, please
open an issue first so we can agree on the direction. Every contribution should
pass `make build` and `make test`.

## License

[Apache License 2.0](LICENSE) — © Daniel Justus

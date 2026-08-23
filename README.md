# Symaira Cockpit (`symcockpit`)

> Diese Maschine: Observability und Steuerung des lokalen Macs.

`symaira-cockpit` ist das Repo der **Cockpit-Produktfamilie** — die drei
macOS-lokalen, permission-behafteten Tools für die Maschine, auf der du
arbeitest (Repo-Konsolidierung 2026-08-21, `repo-konsolidierung.md` §3.3).

## Ein Binary, drei Familien

Seit dem CLI-Umbau (2026-08-22) ist `symcockpit` der einheitliche Entrypoint:

```bash
symcockpit scope scan            # Ports, Container, MCP-Inventar
symcockpit tune doctor           # Thermik/Power/Display-Status
symcockpit operate serve         # GUI-Automation als MCP-Server
symcockpit version               # alle drei Komponenten-Versionen
```

Die Legacy-Binaries `symscope`, `symtune` und `symoperate` sind entfernt
(2026-08-23); ihre Kommandos sind die Family-Subcommands oben. Die
Homebrew-Formeln/Casks der drei Vorgänger sind deprecated und zeigen auf
`symcockpit`.

## Installation

```bash
brew install danieljustus/tap/symcockpit
```

Oder direkt: das Universal-Binary (`arm64` + `x86_64`) aus den
[Releases](https://github.com/danieljustus/symaira-cockpit/releases) laden
und nach `/usr/local/bin` legen. Die Binaries sind **nicht signiert und
nicht notarisiert** — über Homebrew installiert greift Gatekeepers
Quarantäne nicht, beim manuellen Download schon.

`symcockpit` selbst hat eine eigene Produktversion; `tune`, `operate` und
`scope` behalten ihre jeweilige Versionshistorie aus der Zeit als
eigenständige Tools:

```bash
$ symcockpit version
symcockpit 0.1.0 — tune 0.9.3, operate 0.6.1, scope 0.4.1
```

| Package | Familie | These | Sprache |
| :--- | :--- | :--- | :--- |
| [`tune/`](tune/) | `symcockpit tune` (`symtune`) | Thermik, Power, Display, Helligkeit, Token-Kosten | Swift 6 (AppKit/IOKit) |
| [`operate/`](operate/) | `symcockpit operate` (`symoperate`) | GUI-Automation: Screenshots, AX-Tree, Input, Apps/Windows | Swift 6 (AppKit/AX/SCK) |
| [`scope/`](scope/) | `symcockpit scope` (`symscope`) | Inventar: Ports, Container, MCP-Server, Health | Swift 6 |

Jedes Package ist ein eigenständiges SPM-Modul mit eigenem `Package.swift`
(Standalone-First); die CLI-Logik liegt jeweils in einem Library-Target
(`SymTuneCLI`, `SymOperateCLI`, `SymScopeCLI`), das sowohl das Legacy-Binary
als auch den Root-Dispatcher konsumiert. Das Root-`Package.swift` definiert
das `symcockpit`-Dispatcher-Binary über lokale Pfad-Dependencies.

## Build & Test

```bash
# Alles (Root-Makefile)
make build
make test

# Einzelnes Package
cd tune && swift build && swift test
cd operate && swift build && swift test
cd scope && swift build && swift test

# Dispatcher
swift build && .build/debug/symcockpit help
```

> **Toolchain-Hinweis:** Die App-Targets (`SymTuneApp`) und Tests brauchen die
> Xcode-Toolchain. Falls CommandLineTools `swift` Fehler beim App-Build
> meldet (`actool`), mit Xcode(-beta) bauen:
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build`

## Konventionen (Ecosystem)

- Binaries: `symcockpit` (Dispatcher) + Legacy `symtune`, `symoperate`,
  `symscope`.
- XDG-Pfade: `~/.config/<tool>/`, `~/.cache/<tool>/`, `~/.local/share/<tool>/`.
- Env-Präfix: `SYMTUNE_*`, `SYMOPERATE_*`, `SYMSCOPE_*`.
- Exit-Codes: `0` ok · `1` Fehler · `2` Usage/Config · `3` Permission ·
  `4` Unsupported/Not-Implemented (Swift-Tools).
- Zero-Stdio-Pollution in allen MCP-Servern (`serve`): stdout = JSON-RPC nur.
- Public Apache-2.0 — kein Billing/Tenant/Cloud-Code hier.


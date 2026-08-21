# Symaira Cockpit (`symcockpit`)

> Diese Maschine: Observability und Steuerung des lokalen Macs.

`symaira-cockpit` ist das Repo der **Cockpit-Produktfamilie** — die drei
macOS-lokalen, permission-behafteten Tools für die Maschine, auf der du
arbeitest (Repo-Konsolidierung 2026-08-21, `repo-konsolidierung.md` §3.3).

| Package | Binary | These | Sprache |
| :--- | :--- | :--- | :--- |
| [`tune/`](tune/) | `symtune` | Thermik, Power, Display, Helligkeit, Token-Kosten | Swift 6 (AppKit/IOKit) |
| [`operate/`](operate/) | `symoperate` | GUI-Automation: Screenshots, AX-Tree, Input, Apps/Windows | Swift 6 (AppKit/AX/SCK) |
| [`scope/`](scope/) | `symscope` | Inventar: Ports, Container, MCP-Server, Health | Swift 6 (Port aus Go) |

Jedes Package ist ein eigenständiges SPM-Modul mit eigenem `Package.swift`
(Standalone-First): baubar, testbar und nutzbar ohne den Rest des Repos.

## Build & Test

```bash
# Einzelnes Package
cd tune && swift build && swift test
cd operate && swift build && swift test

# Alle Packages (Root-Makefile)
make build
make test
```

> **Toolchain-Hinweis:** Die App-Targets (`SymTuneApp`) und Tests brauchen die
> Xcode-Toolchain. Falls CommandLineTools `swift` Fehler beim App-Build
> meldet (`actool`), mit Xcode(-beta) bauen:
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build`

## Konventionen (Ecosystem)

- Binaries: `symtune`, `symoperate`, `symscope`.
- XDG-Pfade: `~/.config/<tool>/`, `~/.cache/<tool>/`, `~/.local/share/<tool>/`.
- Env-Präfix: `SYMTUNE_*`, `SYMOPERATE_*`, `SYMSCOPE_*`.
- Exit-Codes: `0` ok · `1` Fehler · `2` Usage/Config · `3` Permission ·
  `4` Unsupported/Not-Implemented (Swift-Tools).
- Zero-Stdio-Pollution in allen MCP-Servern (`serve`): stdout = JSON-RPC nur.
- Public Apache-2.0 — kein Billing/Tenant/Cloud-Code hier.

# scope — die `symcockpit scope`-Familie

Port-Inventar & MCP-Discovery. Swift-Port des Go-Originals `symaira-scope`
(repo-konsolidierung.md §6, Schritt 8 — eine Sprache im
`symaira-cockpit`-Repo); das Ursprungs-Repo ist archiviert und die
`symscope`-Formula deprecated.

> Inventar der Maschine: **Ports** (lsof), **Container** (docker CLI),
> **MCP-Server** (AI-Client-Configs) — als CLI und MCP-Server.

## Build & Test

```bash
swift build                # all targets
swift test                 # unit tests
swift run -q symscope doctor
```

Lokale Toolchain: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
(wie tune/operate, CommandLineTools haben kein XCTest).

## CLI

```bash
symscope version               # VersionInfo (--json für Machine-Output, schema_version 1)
symscope scan                  # aggregierter Snapshot (Ports + MCP + Container)
symscope ports list            # lauschende TCP/UDP-Ports mit Prozess
symscope ports suggest [n]     # n freie TCP-Ports vorschlagen (Default 3)
symscope mcp list              # MCP-Server über AI-Client-Configs
symscope mcp health            # Health-Probe aller konfigurierten Server
symscope containers            # laufende Docker-Container (docker ps)
symscope conflicts             # Ports, die von mehreren Prozessen gehalten werden
symscope watch --interval 5    # Änderungen beobachten (NDJSON-Events: port_bound, …)
symscope cache show|clear      # Snapshot-Cache inspizieren/löschen
symscope explain port <p>      # was nutzt Port p (Prozesse + MCP-Server)
symscope explain server <name> # welcher Client/Config gehört zum MCP-Server
symscope serve                 # stdio MCP-Server (JSON-RPC)
```

## Module Layout

```
symscope (executable) → SymScopeMCP → SymScopeCore
```

- `SymScopeCore` — PortService (lsof), MCPDiscovery (symbrain's harness
  inventory when installed, own JSONC config parse as standalone fallback),
  ContainerService (docker), MCPHealthService, ConflictDetector,
  SnapshotService, Models. Keine externen Dependencies (Foundation + Darwin
  only).
- `SymScopeMCP` — stdio JSON-RPC/MCP über `SymairaMCP` (appkit, exact-pinned).
  6 Tools: `scan`, `ports_list`, `ports_suggest`, `mcp_list`, `conflicts`,
  `mcp_health`.
- `symscope` — dünne CLI, Argument-Routing von Hand (kein Cobra-Äquivalent
  nötig).

## Konventionen

- JSON snake_case (`.convertToSnakeCase`), Struktur-äquivalent zum Go-Original.
- Zero-Stdio-Pollution in `serve`: stdout = JSON-RPC frames only.
- Exit-Codes: 0 ok · 1 Fehler · 2 Usage.
- Read-only & lokal für Discovery; keine Netzwerk-Calls außer `mcp health`.
- Binär: `symscope`. Config/Env wie Go-Original (`~/.config/symscope/`,
  `SYMSCOPE_*`) — noch nicht implementiert (Folge).

## Design

Siehe `docs/scope-port.md` für Meilensteine und Abweichungen vom Go-Original
(gopsutil → lsof, cobra → Hand-Router, corekit/mcpserver → SymairaMCP).

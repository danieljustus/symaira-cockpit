# scope Go→Swift-Port — Design

**Status:** Entwurf (2026-08-21) · **Repo:** `symaira-cockpit` · **Ref:** repo-konsolidierung.md §3.3

## Ziel

`symscope` (Port-Inventar, Container, MCP-Discovery, Health, Watch) als
Swift-Package `scope/` im Cockpit portieren — eine Sprache (Swift) im Repo,
wie von Daniel entschieden. `symaira-scope` (Go) bleibt als Referenz offen,
bis der Port funktional gleichwertig ist.

## Umfang (Go-Quellbasis)

| Paket | LoC (Kern) | Swift-Äquivalent |
| :--- | :--- | :--- |
| `internal/mcpcfg` | 905 | `SymScopeMCPConfig` — removed; symbrain is the SSOT |
| `cmd/symscope` | 734 | Swift CLI (ArgumentRouter) |
| `internal/mcphealth` | 297 | `HarnessHealthService` — symbrain view; no local probes |
| `internal/cache` | 251 | `SnapshotCache` (JSON auf XDG-Cache) |
| `internal/ports` | 239 | `PortService` — `lsof`-Parse (statt gopsutil) |
| `internal/explain` | 150 | `ExplainService` |
| `internal/containers` | 147 | `ContainerService` — Docker-CLI-Shellout |
| `internal/watch` | 132 | `WatchService` — FSEvents/Poling |
| `internal/model` | 110 | `Models` (snake_case JSON) |
| `internal/mcptools` | 106 | `MCPToolRegistry` (SymairaMCP aus appkit) |
| `internal/scan` | 86 | `SnapshotService` |
| `internal/output` | 70 | `OutputFormatter` (JSON/NDJSON) |
| `internal/config` + `version` | 37 | `Config`, `Version` |

## Architektur (SPM, wie tune/operate)

```
symscope (executable) → SymScopeMCP → SymScopeCore
```

- `SymScopeCore` — all local inventory logic (PortService, ContainerService,
  HarnessInventoryService, MCPDiscovery, Cache, Watch, Models). MCP discovery
  is a schema-2 view over symbrain; ports, daemons and containers remain
  standalone.
- `SymScopeMCP` — stdio JSON-RPC/MCP-Transport (SymairaMCP aus
  `symaira-appkit`, exact-pinned). 6 Tools: `scan`, `ports_list`,
  `ports_suggest`, `mcp_list`, `conflicts`, `mcp_health`.
- `symscope` — thin CLI: `scan`, `ports`, `mcp`, `containers`, `conflicts`,
  `explain`, `cache`, `watch`, `serve`, `version`.

## Abhängigkeiten / Ersatz

| Go | Swift |
| :--- | :--- |
| `gopsutil/v4` (Prozesse) | `lsof`-Shellout oder `libproc` (kein Drittanbieter) |
| `hujson` (JSONC) | symbrain harness schema 2 (no local parser) |
| `cobra` | Eigener ArgumentRouter (Swift ArgumentParser nicht nötig) |
| `corekit/mcpserver` | `SymairaMCP` (appkit) |
| `tailscale/hujson`, `yaml.v3` | Nur falls Konfig-Formate es brauchen |

## CLI-Kompatibilität

- `symscope scan` → Snapshot JSON (gleiche snake_case-Struktur)
- `symscope ports list|suggest`, `symscope mcp list|health`, `symscope containers`, `symscope conflicts`, `symscope explain port|server`,
  `symscope cache show|clear|stats`, `symscope serve`
- `mcp list|health` requires symbrain; ports, daemons and containers remain
  usable when symbrain is absent.
- `version --json` mit `schema_version: 1` (SymairaToolKit-Handshake)

## CI / Verifikation

- CI-Matrix im Cockpit: `pkg: [tune, operate, scope]` — `scope` wird
  aktiviert, sobald das Package grün ist (aktuell ausgenommen).
- Tests: Unit für Port-Parsing (Fixtures), MCP-Discovery (Config-Fixtures),
  JSONC-Stripper, Cache-Roundtrip. Kein Test setzt ein echtes Tool voraus.

## Meilensteine

1. `scope/` SPM-Skelett + Models + CLI-Router (`version`, `serve`-Stub)
2. `PortService` (lsof-Parse) + `ports list/suggest` + Tests
3. `MCPDiscovery` (JSONC) + `mcp list` + Tests
4. `ContainerService` (docker-CLI) + `containers` + Tests
5. Health/Scan/Watch/Cache + `scan` aggregiert + MCP-Tools
6. CI grün, README, PR → merge → `symaira-scope` archivieren, Formel bleibt
   deprecated

## Nicht-Ziele

- Kein SwiftUI-Client im ersten Schritt (bestehender `client/` aus Go-Repo
  ist eine separate Frage, gehört zu Hub-Consolidierung).
- Kein Bit-identisches JSON — Struktur-Äquivalenz reicht.

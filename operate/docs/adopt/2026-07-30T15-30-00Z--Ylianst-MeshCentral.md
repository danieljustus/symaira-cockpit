<!-- review: timestamp=2026-07-30T15:30:00Z  repo=danieljustus/symaira-operate  head=70e28fb -->
<!-- adopt: source=Ylianst/MeshCentral  source_ref=master  source_url=https://github.com/Ylianst/MeshCentral  depth=clone  license=Apache-2.0 -->

# Adoption Report — danieljustus/symaira-operate ← Ylianst/MeshCentral — 2026-07-30

## Sources

| Field | Value |
|---|---|
| SOURCE | `Ylianst/MeshCentral` (https://github.com/Ylianst/MeshCentral) |
| Ref analyzed | `master` (default branch) |
| Language / License | JavaScript / Apache-2.0 |
| Health | 6,981 stars, last push 2026-07-27, active releases (v1.2.4) |
| Scope | architecture (agent protocol, permission system, plugin system), security (auth, certs), testing |
| TARGET | `danieljustus/symaira-operate` @ `70e28fb` |

## Verdict

MeshCentral ist ein hochreifes RMM-System (Node.js, 61k LOC) mit ausgefeilter Agenten-Kommunikation, granularer Rechteverwaltung und Multi-Backend-DB-Abstraktion. Für symaira-operate (Swift, 6.5k LOC, lokale macOS-GUI-Automation) sind die Überschneidungen begrenzt — MeshCentral adressiert Remote-Management, operate lokale Automation. **Ein Finding** überlebt die vier Gates: das bitfield-basierte Rechtesystem als Inspiration für operate's ActionPolicy. Die meisten MeshCentral-Stärken (Agent-Protokoll, WebRTC-Relay, Plugin-System) passen nicht zu operate's lokaler, kurzlebiger MCP-Architektur.

## What we already do as well or better

- **Multi-Display-Handling** → MeshCentral's KVM supports display selection (`MNG_KVM_GET_DISPLAYS`/`MNG_KVM_SET_DISPLAY`). Operate's v0.2 already implements multi-display capture and selection.
- **Safety-Guard-System** → MeshCentral uses bitfield rights separated by domain (remote control vs files vs terminal). Operate's `ActionPolicy` (keyword-based deny/allow) ist ein anderer Ansatz, der für die lokale Automation angemessen ist.
- **Event Logging / History** → MeshCentral's `dataAccounting` Tracker. Operate's `history --json` erfüllt denselben Zweck.

## Findings

- [ ] **[Architecture] Composable Permission Flags für ActionPolicy**
  - **Status quo:** Operate's `ActionPolicy` ist monolithic keyword-basiert: `defaultDenyKeywords` + `extraDenyKeywords` + `allowedKeywords` + `allowedBundleIDs`. Jede Entscheidung ist binär (destruktiv ja/nein). Issue #60 dokumentiert, dass Safety-Refusals als freitext `-32000` Errors bei MCP-Clients ankommen — maschinenlesbar wären sie mit einer strukturierten Permission-Struktur. Granular Policies (z.B. "Screenshots erlauben, Clicks blockieren") sind aktuell nicht abbildbar.
  - **Proposed solution (pattern adoption):** Führe ein `OptionSet`-basiertes Permission-Flag-System analog zu MeshCentral's `MESHRIGHT_*` Bitfield-Konstanten (`meshrelay.js:12-40`) ein. Jeder Permission-Flag repräsentiert eine Tool-Kategorie (z.B. `capture`, `input`, `appControl`, `policyModify`). `ActionPolicy` evaluiert Flags statt Keyword-Matching. Safety-Refusals liefern das verletzte Flag als strukturierten Enum-Wert. MeshCentral's 32-Bit-Design (`MESHRIGHT_ADMIN = 0xFFFFFFFF`) zeigt, wie Flags granular erweiterbar bleiben.
  - **Effort/Impact:** Medium effort / High impact. Löst #60 (maschinenlesbare Refusals) und ermöglicht granulare Policies ohne Bruch der existierenden API. Reversibel: die alten `extraDenyKeywords`/`allowedKeywords` können als Kompatibilitäts-Interface erhalten bleiben. Swift's `OptionSet` macht die Implementierung trivial.

## Considered and rejected

- **Agent WebSocket-Protokoll mit Zertifikats-Handshake** — Gate 1 (Transferable): MeshCentral's agent-to-server WebSocket-Protokoll (`meshagent.js:18-680`) mit asymmetrischer Authentifizierung und Nonce-basiertem Challenge-Response ist für Remote-Agents konzipiert. Operate ist ein lokaler MCP-Server ohne Remote-Agent-Architektur. Das Protokoll wäre Overkill.
- **KVM Remote Desktop Protocol** — Gate 1 (Transferable): `meshdesktopmultiplex.js` implementiert ein binäres Kommando-Protokoll (MNG_KVM_*) für Screen-Capture, Input-Injektion und Clipboard-Sync. Operate nutzt macOS-native Frameworks (ScreenCaptureKit, CGEvent) — binäre Protokollebene ist weder nötig noch übertragbar.
- **Plugin-System** — Gate 4 (Worth it): MeshCentral's `pluginHandler.js` lädt Node.js-Module dynamisch aus einem Plugin-Verzeichnis mit Hook-Event-System. Für operate (6.5k LOC, 127 Tests, lokales Tool) wäre ein Plugin-System Architektur-Overhead ohne aktuellen Bedarf. Revisit bei >15k LOC oder bei konkretem Extension-Wunsch.
- **Multi-Backend Database Abstraction** — Gate 1 (Transferable): `db.js` (4.277 Zeilen, 3 Backends) abstrahiert NeDB/MongoDB/SQLite. Operate hat keine Datenbank-Persistenz außer MCP-State. Kein Bedarf.
- **Event-basiertes Messaging (Telegram/Messenger)** — Gate 1 (Transferable): `meshmessaging.js` integriert Telegram-Benachrichtigungen. Operate ist ein lokales Automationstool — kein Anwendungsfall für externe Messaging-Integration.
- **Config Schema Validation (200KB JSON Schema)** — Gate 4 (Worth it): MeshCentral's `meshcentral-config-schema.json` validiert die gesamte Server-Konfiguration. Operate hat kein Config-File — die Policy wird über MCP-Tools gesetzt. Schema-Validierung wäre hier sinnlos.

## Open questions

- Keine — die Analyse ist für operate's aktuellen Scope ausreichend.

---

Best first step: Ersetze `ActionPolicy.isDestructive()` durch ein `PermissionFlags` OptionSet und portiere die Safety-Refusals auf strukturierte Enum-Werte (Issue #60).

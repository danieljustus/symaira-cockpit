# Umsetzung: Symaira Cockpit 2

> Auftrag Daniel 2026-11-20: „bau du bitte alles fertig“. Arbeitsweise: lokal integrieren und prüfen, Unteragenten je Arbeitspaket in eigenen Worktrees unter `Symaira_Dev/Worktrees/symaira-cockpit/`, Push erst am Ende eines Laufs. Menschliche Abnahmen (Freigabedialoge, sudo, Hardware-Matrix, 30-Tage-Nutzung, Release) werden gesammelt und am Ende in einer Sitzung erledigt.

## Stand

| Welle | Paket | Status | Beleg |
|---|---|---|---|
| 0 | F1 Rust-Workspace, Befehlsregister (38 Befehle, 26 MCP-Tools wertgleich), Weiterleitung an Swift, Orakel-Harness, CI | ✅ 2026-11-20 integriert; fmt, clippy, 35 Tests grün | `main` f4dba0d bis 27387c6 |
| 0 | F2 Orakel-Fixtures aus Swift v0.12 (70 Fälle) | ✅ 2026-11-20; Abnahme Stufe 0: 70/70 grün gegen Swift und gegen das weiterleitende Rust-Binary | `oracle/v0.12/`, Rohdaten `Dev/evidence/symaira-cockpit/cockpit2-oracle/` |
| 0 | F4 Desktop-Issue PDF-Kompression | ✅ [symaira-desktop#1408](https://github.com/danieljustus/symaira-desktop/issues/1408) | |
| 0 | F3 Produktvertrag Revision 9 | ✅ 2026-11-20, kanonisch plus 8 Repos lokal committet | `Repos/docs/product-boundaries.md`, Backup `Repos/docs/docs-sync/2026-11-20-cockpit2-rev9/` |
| 1 | Lesepfad: SMC, Sensoren, Lüfter, Leistung, IOReport, GPU, Prozesse, Akku, Displays; CLI und die 12 MCP-Lesetools aus Rust (von 26 Tools insgesamt) | ✅ 2026-11-20 integriert; Orakel 70/70 voll und ohne Swift-Binary | `main` bis fcd8e78 |
| 3, 4, 5 | Speicher (Gesundheit, Speedtest, Platz, Plan-Engine, Bereinigung, Duplikate, Deinstallation), Audio und MIDI, Bluetooth und Eingabe | ✅ 2026-11-21 integriert und in CLI und MCP verdrahtet (24 neue MCP-Tools, riskante nur als `plan_*`/`confirm_plan`), ein SQLite-Zugang, Prozess beenden über Plan (R12), Orakel „v0.12-Tools exakt, neue nur deklariert“ | `main` bis 57caace |
| 2 | 2A Rust-Helfer (XPC, Heartbeat, Governor), SMC-Schreibpfad, Lüfter, Ladegrenze nach Vorhandensein, SMC-Restore; 2B Helligkeit, EDR, Dimmen, Wärme, Wachhalten, Profile, Display-Restore; 2C App-Agent `agent --stdio` mit Swift-`AgentClient` | ✅ 2026-11-21 integriert: ein `restore` (Display-Hälfte, dann SMC-Handler), MCP-Schreibtools nativ, Test-Schutzschalter `SYMCOCKPIT_TEST_NO_HARDWARE` (nur Debug) | `main` 0d4633d |
| 6 | Finder und Zwischenablage: FFI-Staticlib, Quick-Look- und FinderSync-Erweiterung im Bundle, Finder-Aufträge, Zwischenablageverlauf (CLI nur status/pause/resume/clear) | ✅ 2026-11-21 integriert | `main` 0d4633d |
| Abnahme 2026-11-21 | Integrationsstand `main` 0d4633d | ✅ fmt, clippy sauber; Rust 851 Tests grün (21 ignoriert, live); Orakel 70/70 voll und nativ; Swift `make test`, Root-`swift test` (123 Tests, 4 übersprungen), AgentClient 11 Tests; `make build-app` und `make smoke-app` mit beiden Erweiterungen | Logs `~/.hermes/cache/scratch/int2-*.log` |
| 2D-1 | Letzte Weiterleitungen an Swift nativ: `fan profile\|target` setzen (Swift-Datei und History-Zeile, Agent: Plan, Argument `profile` bzw. `celsius`, `null` löscht), `status --watch` (NDJSON, SIGINT/SIGPIPE sauber), `ai-usage serve` (TcpListener, Antworten byteweise wie Swift gegen das echte v0.12.2-Binary geprüft), Updateprüfung bei `version` (curl-Kindprozess, Cache-Datei wie corekit), Nicht-UTF-8-Argumente (U+FFFD wie Swift). `legacy.rs`, `forward`, `through_legacy` und `App.legacy` sind entfernt: kein CLI-Befehl und kein MCP-Tool startet im Produktionsbinary noch Swift (`tests/no_swift.rs`: Köder an allen drei Fundorten, jeder v0.12-Befehl und alle 26 Tools) | ✅ 2026-11-21 lokal auf `c2/w2d-cli` (Basis `c2/int-2` 734832c), noch nicht integriert | |
| 2D-2 | App auf den Agenten | ✅ in `c2/int-2` | |
| 2D-3 | Bedienoberflächen der neuen Bereiche, danach Swift-Kern entfernen | ⏳ als Nächstes | |
| 7 | Release-Vorbereitung (arm64, Signatur, Cask mit CLI-Link, Formula nur CLI) | offen | |

## Gesammelte menschliche Abnahmen (am Ende)

1. Spike-Sitzung nach `Dev/evidence/symaira-cockpit/cockpit2-spikes/SITZUNG.md` (S1, S2, S4, S6, S8).
2. Hardware-Matrix opt-in für Lüfter und Ladegrenze (Stufe 2).
3. Freigaben für Bluetooth, Bedienungshilfen, Audioaufnahme, Finder-Erweiterung an der fertigen App.
3a. Erste echte Schreibtests mit dem Rust-Binary: Helligkeit, Dimmen, Wärme, EDR, Wachhalten (Display), Lüfter als root und über den Helfer, Ladegrenze über PowerUI (dieser Mac hat keinen SMC-Ladeschlüssel, der Weg ist unbelegt), je mit Readback und `restore`.
4. Push der lokalen Commits (Cockpit und die 8 Repos mit Vertragsrevision 9).
5. Release-Freigabe und 30 Tage Alltagsnutzung je Stufe (Z1).

## Regeln für jedes Paket

- Bauen nur über `dev-external`; Volume hat wenig freien Platz, Reserve vor jedem großen Build prüfen.
- Tests beschreiben keine Hardware; Plattformquellen haben Fakes (Q07).
- Orakel bleibt grün; neue Befehle bekommen Schema-Snapshots.
- Jede Welle endet mit Integration auf `main`, vollem Testlauf (Rust und Swift) und einem Eintrag oben.

# Umsetzung: Symaira Cockpit 2

> Auftrag Daniel 2026-11-20: „bau du bitte alles fertig“. Arbeitsweise: lokal integrieren und prüfen, Unteragenten je Arbeitspaket in eigenen Worktrees unter `Symaira_Dev/Worktrees/symaira-cockpit/`, Push erst am Ende eines Laufs. Menschliche Abnahmen (Freigabedialoge, sudo, Hardware-Matrix, 30-Tage-Nutzung, Release) werden gesammelt und am Ende in einer Sitzung erledigt.

## Stand

| Welle | Paket | Status | Beleg |
|---|---|---|---|
| 0 | F1 Rust-Workspace, Befehlsregister (38 Befehle, 26 MCP-Tools wertgleich), Weiterleitung an Swift, Orakel-Harness, CI | ✅ 2026-11-20 integriert; fmt, clippy, 35 Tests grün | `main` f4dba0d bis 27387c6 |
| 0 | F2 Orakel-Fixtures aus Swift v0.12 (70 Fälle) | ✅ 2026-11-20; Abnahme Stufe 0: 70/70 grün gegen Swift und gegen das weiterleitende Rust-Binary | `oracle/v0.12/`, Rohdaten `Dev/evidence/symaira-cockpit/cockpit2-oracle/` |
| 0 | F4 Desktop-Issue PDF-Kompression | ✅ [symaira-desktop#1408](https://github.com/danieljustus/symaira-desktop/issues/1408) | |
| 0 | F3 Produktvertrag Revision 9 | ✅ 2026-11-20, kanonisch plus 8 Repos lokal committet | `Repos/docs/product-boundaries.md`, Backup `Repos/docs/docs-sync/2026-11-20-cockpit2-rev9/` |
| 1 | Lesepfad: SMC, Sensoren, Lüfter, Leistung, IOReport, GPU, Prozesse, Akku, Displays; CLI und die 12 MCP-Lesetools aus Rust (von 26 Tools insgesamt); Prozess beenden über Plan | ⏳ 5 Worker parallel (1A SMC und Sensoren, 1B Akku und Energie, 1C Displays, 1D Metriken und Prozesse, 1E Dispatcher, serve, Systembefehle) | |
| 2 | Schreibpfad, Rust-Helfer, Agent-Protokoll, App auf Rust, Swift-Kern entfernen | offen | |
| 3 | Speicher | offen | |
| 4 | Audio und MIDI | offen | |
| 5 | Bluetooth und Eingabe | offen | |
| 6 | Finder und Zwischenablage | offen | |
| 7 | Release-Vorbereitung (arm64, Signatur, Cask mit CLI-Link, Formula nur CLI) | offen | |

## Gesammelte menschliche Abnahmen (am Ende)

1. Spike-Sitzung nach `Dev/evidence/symaira-cockpit/cockpit2-spikes/SITZUNG.md` (S1, S2, S4, S6, S8).
2. Hardware-Matrix opt-in für Lüfter und Ladegrenze (Stufe 2).
3. Freigaben für Bluetooth, Bedienungshilfen, Audioaufnahme, Finder-Erweiterung an der fertigen App.
4. Push der lokalen Commits (Cockpit und die 8 Repos mit Vertragsrevision 9).
5. Release-Freigabe und 30 Tage Alltagsnutzung je Stufe (Z1).

## Regeln für jedes Paket

- Bauen nur über `dev-external`; Volume hat wenig freien Platz, Reserve vor jedem großen Build prüfen.
- Tests beschreiben keine Hardware; Plattformquellen haben Fakes (Q07).
- Orakel bleibt grün; neue Befehle bekommen Schema-Snapshots.
- Jede Welle endet mit Integration auf `main`, vollem Testlauf (Rust und Swift) und einem Eintrag oben.

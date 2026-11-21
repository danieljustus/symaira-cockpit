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
| 3, 4, 5 | Speicher (Gesundheit, Speedtest, Platz, Plan-Engine, Bereinigung, Duplikate, Deinstallation), Audio und MIDI, Bluetooth und Eingabe als Rust-Bereiche | ✅ 2026-11-21 zusammengeführt; fmt, clippy sauber, 527 Tests grün, Orakel 70/70 voll und nativ; Verdrahtung in CLI und MCP läuft (Integration 2, inkl. Prozess beenden über Plan) | `main` 5f43dd4 |
| 2 | Schreibpfad: 2A Rust-Helfer, Lüfter, Ladegrenze, SMC-Restore; 2B Helligkeit, EDR, Dimmen, Wärme, Wachhalten, Profile; 2C App-Agent; danach 2D App auf Rust und Swift-Kern entfernen | ⏳ 2A bis 2C laufen parallel (Neustart 2026-11-21 nach Rate-Limit-Abbruch) | |
| 6 | Finder und Zwischenablage | ⏳ läuft parallel | |
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

# Symaira Cockpit 2: Rust-Neuaufbau als Maschinenraum des Macs

> Spur: A (bestehendes Produkt, Vertragsänderung nötig) · Modus: standard · Stand: 2026-11-20 · **Architektur freigegeben (2026-11-20, Daniel)**

## Ergebnis zuerst

Cockpit 2 ersetzt 13 der 16 geprüften Werkzeuge ganz oder teilweise durch einen Rust-Kern mit CLI, MCP-Server und schlanker SwiftUI-App. PDF Squeezer gehört nach Desktop, wo bereits eine Rust-PDF-Engine existiert. Automator und Cyberduck passen nicht und werden nicht nachgebaut. Voraussetzung ist Revision 9 des Produktvertrags, weil Cockpit heute auf Thermik, Strom, Display, Sensoren und HUD begrenzt ist.

## Status

| Phase | Dokument | Status |
|---|---|---|
| 0 Aufnahme | [00-idee](00-idee.md) | ✅ freigegeben |
| 1 Recherche | [01-recherche](01-recherche.md) | ✅ G1 bestanden (2026-11-20) |
| 2 Produktbrief | [02-produktbrief](02-produktbrief.md) | ✅ Umfang bestätigt (G2, 2026-11-20) |
| 3 Lösungsoptionen | [03-loesungsoptionen](03-loesungsoptionen.md) | ✅ G3 bestanden, Option A (2026-11-20) |
| 4 Architektur | [04-architektur](04-architektur.md), [ADRs](../../adr/) | ✅ G4 bestanden (2026-11-20) |
| 5 Validierung und Roadmap | [05-validierung-und-roadmap](05-validierung-und-roadmap.md) | ✅ G5 freigegeben (2026-11-20) |
| 6 Übergabe | dieses README | ✅ |

Recherchematerial: [research/SOURCES.md](research/SOURCES.md), [research/candidates.json](research/candidates.json).

## Bestätigte Entscheidungen

Alle am 2026-11-20 (G1/G2), vollständig in [entscheidungen.md](entscheidungen.md):

- D01, D12: Neuaufbau im Repo `symaira-cockpit`, Rust neben Swift, Parität per v0.12-Fixtures, dann Swift-Kern abschalten.
- D02, D13: Cockpit umfasst Monitor, Tuning, Speicher, Audio und MIDI, Bluetooth, Eingabe, Finder und Zwischenablageverlauf.
- D03: PDF-Kompression kommt als `symdesk pdf compress` nach Desktop.
- D04, D05: Automator und Cyberduck vorerst nicht nachbauen.
- D09: SMC, IOReport, IORegistry und MultitouchSupport (Haptik) ab Start erlaubt, mit Fähigkeitserkennung.
- D06, D14 (G3): Rust-Binary `symcockpit` ist CLI, MCP und App-Agent; die SwiftUI-App startet es als Kindprozess.
- D10 (G3): Riskante Agentenaktionen in zwei Schritten, Harmloses direkt, Eingabe und Haptik nie über MCP.
- D13 (G3): Zwischenablageverlauf nur für den Menschen, kein Agentenzugriff.
- D15 (G3): Cask liefert App plus CLI-Link, Formula nur CLI, gegenseitig ausschließend.

## Offene Fragen

1. Technisch offen (04 §15): Bau der App-Erweiterungen (Spike S6), Zukunft von `history.ndjson`, btleplug oder objc2-core-bluetooth.
2. Vertragstext Revision 9 (D02) folgt in Stufe 0; Desktop-Planung für PDF-Kompression (D03) im Desktop-Repo.

## Nächste Aktion

Gemeinsame Sitzung mit Daniel am Mac für S1, S2, S4, S6 und S8: Ablauf in `Dev/evidence/symaira-cockpit/cockpit2-spikes/SITZUNG.md`. Alle Prototypen sind gebaut und signiert, keiner ist bisher gelaufen.

## Spike-Stand

| Spike | Status | Evidenz |
|---|---|---|
| S1 TCC-Rechte Kindprozess | ⏳ vorbereitet: signierte App plus Rust-Kind mit 6 Sonden, braucht Daniel (Dialoge) | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S1/RUNBOOK.md` |
| S2 IOReport gegen powermetrics | ⏳ ohne root 60 s gemessen, plausibel (macmon 0.12 als Bibliothek); Vergleich braucht Daniel (sudo) | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S2/REPORT.md` |
| S3 NVMe-SMART aus Rust | ✅ teilweise bestanden: ohne root lesbar, Zahlenwerte ohne unabhängige Referenz | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S3/REPORT.md` |
| S4 Process Tap aus Rust | ⏳ vorbereitet: signierte App, 32 Unit-Tests; braucht Daniel (Audioaufnahme, Hören) | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S4/RUNBOOK.md` |
| S5 SMC-Port gegen Swift | ✅ bestanden (nur M4 Pro, macOS 27.2.1); Befunde #420, #421 | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S5/REPORT.md` |
| S6 Erweiterungen bauen | ⏳ Skript-Bau ohne Xcode-Projekt gelungen, signiert; Registrierung und Anzeige braucht Daniel | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S6/RUNBOOK.md` |
| S8 Ladegrenze ohne SMC-Schlüssel | ⏳ lesend bestanden: macOS-Ladegrenze antwortet ohne root; Schreibtest braucht Daniel | `Dev/evidence/symaira-cockpit/cockpit2-spikes/S8/REPORT.md` |

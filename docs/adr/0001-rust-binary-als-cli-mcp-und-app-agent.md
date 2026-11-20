# ADR 0001: Ein Rust-Binary ist CLI, MCP-Server und App-Agent

- Status: angenommen (2026-11-20, Daniel, Gate G4/G5 der Planung [Cockpit 2](../plans/2026-11-20-cockpit-2/README.md))
- Bezug: R01, R02, R04, R06, Q02, Q04, Q07; Risiko K1

## Kontext

Cockpit soll für Menschen und Agenten gleich gut nutzbar sein und darf in der App nichts zeigen, was die CLI widerlegt (AGENTS.md). Desktop (`DeskTransport` mit Befehlen und NDJSON-Streams), Brain (`MemoryClient`) und Voice binden ihre Swift-Apps bereits über das eigene CLI-Binary an. Kein Symaira-Repo nutzt UniFFI oder swift-bridge (geprüft 2026-11-20).

## Entscheidungstreiber

- Ein Vertrag für CLI, MCP und App
- Geringste Rechte, keine Dauerläufer allein durch Installation (PB §7)
- Testbarkeit über einen Drahtvertrag
- Rechtegebundene Live-Funktionen (Event-Tap, Zwischenablage, Process Taps, Haptik, BLE)

## Optionen

| Option | Vorteile | Nachteile |
|---|---|---|
| Binary mit Modi CLI, `serve`, `agent`; App startet `agent` als Kindprozess | Ein Einstieg, Präzedenz im Ökosystem, Absturzisolation | TCC-Zuordnung des Kindprozesses ungeprüft |
| Rust-Bibliothek in der App (UniFFI) | Rechte gehören sicher der App, kein IPC | Zwei Einstiege, xcframework-Bau, Rust-Fehler beendet die App, keine Präzedenz |
| Dauer-Daemon mit Clients | Ein Zustandsbesitzer | Dauerläufer, eigene TCC-Identität, Lebenszyklusaufwand |

## Entscheidung

Option 1. Das Befehlsregister in `symcockpit-contract` erzeugt CLI-Befehle, MCP-Tools und Agent-Methoden. Der Agent nimmt Verbindungen nur an, wenn sein Elternprozess die signierte Cockpit-App ist. Riskante Aktionen laufen für Agenten in zwei Schritten (Plan mit Ablauf, Bestätigung mit Plan-ID); `human_only`-Befehle erscheinen nie in MCP (D10, D13).

## Konsequenzen

- Positiv: Die App kann keine eigene Wahrheit entwickeln; Tests konzentrieren sich auf Schemas.
- Negativ: Prozessstart und JSON-Kodierung kosten etwas Zeit; Live-Daten brauchen Abonnements.
- Folgearbeit: Protokollversion und Handshake; Elternprüfung; Spike S1.

## Prüfung

Falsch, wenn S1 zeigt, dass Bluetooth, Bedienungshilfen oder Audioaufnahme im Kindprozess nicht mit den App-Rechten funktionieren. Dann wechseln nur diese Funktionen in eine Rust-Bibliothek innerhalb der App.

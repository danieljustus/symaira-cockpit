# ADR 0003: Strangler-Migration mit Swift v0.12 als Orakel

- Status: angenommen (2026-11-20, Daniel, Gate G4/G5 der Planung [Cockpit 2](../plans/2026-11-20-cockpit-2/README.md))
- Bezug: R05, Q09, Z5; Risiko K2

## Kontext

Der Swift-Bestand hat 33.410 Quellzeilen und 25.662 Testzeilen. Er trägt teuer gelernte Regeln: SMC-Parameterblock in Host-Byteordnung, Nutzdaten je Typ mit eigener Byteordnung (#185), Plausibilitätsgate für M4-Pro-Sensoren, ein einziger Besitzer der Gamma-Tabelle, EDR braucht Overlay und Gamma.

## Entscheidung

Rust-Workspace im selben Repo neben `tuning/` und `history/`. Vor jedem Port werden die Swift-Ausgaben eingefroren: JSON-Schemas je Befehl, `tools/list`, Exit-Codes, Dateiformate und Testvektoren aus den Swift-Tests. Lesebefehle wechseln zuerst, Schreibbefehle mit Hardware-Abnahme danach, die App zuletzt. Der Swift-Kern wird erst entfernt, wenn alle Fixtures grün sind und die Hardware-Matrix bestanden ist.

## Konsequenzen

- Positiv: Jede Stufe ist rückrollbar; Nutzer merken den Sprachwechsel nicht.
- Negativ: Zeitweise doppelte Pflege; CI baut Swift und Rust.
- Folgearbeit: Werkzeug zum Einfrieren der Orakelausgaben; CI-Bereichstabelle (`scripts/ci-changed-areas.sh`) um Rust ergänzen.

## Prüfung

Falsch, wenn Paritätspflege dauerhaft mehr kostet als neue Funktionen; dann Paritätsumfang auf öffentlich dokumentierte Felder begrenzen.

# ADR 0002: Produktumfang von Cockpit und Vertragsrevision 9

- Status: angenommen (2026-11-20, Daniel, Gate G4/G5 der Planung [Cockpit 2](../plans/2026-11-20-cockpit-2/README.md))
- Bezug: alle Bereichsanforderungen R10 bis R73

## Kontext

PB-2026-09-09 Revision 8 gibt Cockpit nur Thermik, Strom, Display, Sensoren und HUD. Daniel will 16 Werkzeuge ersetzen. Recherche: PDF-Ausgabe gehört Desktop, Ports, Container, Daemons und MCP-Inventar gehören Scope, Fensteraktionen Operate ([01-recherche](../plans/2026-11-20-cockpit-2/01-recherche.md)).

## Entscheidung

Cockpit besitzt künftig Mac-Hardware, Systemzustand und Systemwartung: Monitor (inklusive Ressourcen je Prozess), Tuning, Speicher (SMART, Geschwindigkeit, Platz, Bereinigung, Deinstallation), Audio und MIDI, Bluetooth, Eingabe (Finder-⌘X, Haptik), Finder-Integration (Quick Look, Kontextaktionen) und einen Zwischenablageverlauf nur für den Menschen. Nicht Cockpit: PDF-Kompression (Desktop), Automator, Cyberduck, Ports, Container, Daemons, MCP-Inventar, Harness-Log-Parsing, Fensteraktionen.

## Konsequenzen

- Revision 9 der kanonischen Datei `Symaira_Dev/Repos/docs/product-boundaries.md` mit byte-gleichen Snapshots in allen Repos, erst nach G5.
- Eingabeflächen (⌘X, Haptik) sind wie Diktat in Desktop menschliche Oberflächen; kein MCP-Tool, Agentenprofil oder Brain-Modul darf sie auslösen.
- Die Abgrenzung zu Scope wird im Vertrag ausdrücklich benannt: Ressourcen je Prozess hier, Dienste und Ports dort.

## Prüfung

Neu prüfen, wenn ein Bereich nach seiner Stufe 30 Tage lang keinen Nutzen zeigt (Z1) oder wenn Brain Scope Prozessressourcen ebenfalls braucht; dann gemeinsame Semantik prüfen statt doppelt bauen.

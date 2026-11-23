# Produktbrief: Symaira Cockpit (Rust-Neuaufbau) v0.1

> Status: freigegeben (2026-11-20, Daniel; Umfang G1/G2, Architektur G4/G5) · Basis: [01-recherche.md](01-recherche.md) · Entscheidungen: [entscheidungen.md](entscheidungen.md)

## Ergebnis zuerst

Symaira Cockpit wird mit dem Rust-Neuaufbau der **Maschinenraum des Macs**: ein Rust-Kern mit einer CLI (`symcockpit`), einem MCP-Server und einer schlanken SwiftUI-App für Menüleiste, HUD und Fenster. Es ersetzt 13 der 16 geprüften Werkzeuge ganz oder teilweise in sieben Fachbereichen: Monitor, Tuning, Speicher, Audio und MIDI, Bluetooth, Eingabe, Finder einschließlich Zwischenablageverlauf (D02, D13). PDF-Kompression wandert nach Desktop (D03); Automator und Cyberduck werden vorerst nicht nachgebaut (D04, D05). Trackpad-Haptik über die private Schnittstelle ist ab Start erlaubt (D09). Das MVP ist die Rust-Parität des heutigen Cockpits plus Monitor (Stufen 1 und 2 in [05-validierung-und-roadmap](05-validierung-und-roadmap.md)); Speicher folgt als erster neuer Bereich.

## 1. Problem und Kosten des Nichtstuns

Heute verteilen sich Hardware- und Systemaufgaben auf 16 Programme mit eigenen Hintergrundprozessen, Helfern und Rechten: Burrow (XPC-Helfer), Vorssaint (Lüfter-Helfer), DriveDx (Login-Helfer, kext-Paket), MouseBoost Pro (Finder-Erweiterung, Login-Helfer), Folder Preview (zwei Quick-Look-Erweiterungen). Mehrere verlangen Lizenzen. Nur Burrow bietet einen Agentenzugang. Agenten können den Mac deshalb kaum strukturiert lesen, und jede Aktion läuft über eine andere Oberfläche. Cockpit selbst ist in Swift gebaut, während das übrige Ökosystem auf Rust und CoreKit umzieht; die App verbraucht laut #418 dauerhaft rund 60 % CPU.

## 2. Zielgruppe und Jobs to be done

| Persona | Situation | Job | Heutige Lösung |
|---|---|---|---|
| Daniel (Power-User, Entwickler) | Arbeitet auf MacBook M4 Pro, viele Agenten parallel | Wenn der Mac heiß, voll oder langsam wird, möchte ich Ursache und Abhilfe an einer Stelle sehen, damit ich nicht fünf Apps öffnen muss | Aktivitätsanzeige, Stats-ähnliche Menüleiste, Burrow, DriveDx |
| AI-Agent (Hermes, Claude Code, Codex) | Arbeitet über MCP oder Shell | Wenn ich eine Diagnose stelle, möchte ich strukturierte, ehrliche Messwerte und sichere Aktionen, damit ich nichts zerstöre | Burrow-MCP, Shell-Befehle mit Textausgabe |
| Mac-Nutzer allgemein (öffentliches Apache-2.0-Produkt) | Will Wartung ohne Abo und ohne Telemetrie | Wenn ich aufräume oder deinstalliere, möchte ich vorher sehen, was gelöscht wird, damit nichts Fremdes verloren geht | CleanMyMac-artige Werkzeuge, Uninstaller |

## 3. Ziele und Erfolgskriterien

| Ziel | Messgröße | Zielwert (Vorschlag) |
|---|---|---|
| Z1 Ersatz | Originale, die Daniel 30 Tage nach einer Stufe nicht mehr öffnet | alle der jeweiligen Stufe zugeordneten Originale |
| Z2 Ein Vertrag | Lesefunktionen mit CLI-Befehl, MCP-Tool und Schema-Snapshot | 100 % |
| Z3 Sicherheit | Schreibende oder löschende MCP-Aufrufe ohne gültigen Plan | 0 (automatisierter Test) |
| Z4 Effizienz | CPU-Mittel der Menüleisten-App im Leerlauf über 10 min auf M4 Pro | ≤ 1 % |
| Z5 Parität | Orakelfixtures aus Swift v0.12 grün vor Abschaltung des Swift-Kerns | 100 % |

## 4. Nicht-Ziele

- Mac App Store, Windows, macOS Intel.
- Cloud, Konto, Telemetrie, Pro-Edition.
- PDF-Verarbeitung: gehört Desktop (PB §1); Vorschlag `symdesk pdf compress` in `symdesk-render`.
- Generische Workflow-Engine (Automator): Kurzbefehle und Brain übernehmen Automation.
- Remote-Dateiübertragung (Cyberduck).
- Ports, Container, Daemons, MCP-Inventar: bleiben bei Brain Scope.
- Harness-Log-Parsing und Kostenschätzung: bleiben bei Brain (`symbrain usage`).
- App-Wechsler, Dock-Vorschau, Fensteraktionen, Spaces (Vorssaint): Fenstersteuerung ist Operate-Domäne in Brain.

## 5. Anforderungen

Priorität: **Muss** gehört zum Gesamtprodukt, **MVP** markiert Stufe 1 bis 2, **Später** und **Nie** wie üblich.

### Querschnitt

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R01 | Als Nutzer möchte ich jede Fähigkeit als `symcockpit`-Befehl mit `--json` | WENN ein Befehl läuft DANN SOLL stdout gültiges JSON mit stabilen snake_case-Feldern enthalten und der Exit-Code 0 bis 4 bedeuten | MVP | Bestand |
| R02 | Als Agent möchte ich dieselben Fähigkeiten als MCP-Tools | WENN `symcockpit serve` läuft DANN SOLL stdout nur JSON-RPC enthalten und jedes Lese-Tool einem CLI-Befehl entsprechen | MVP | Bestand |
| R03 | Als Nutzer möchte ich ehrliche Fähigkeitsangaben | WENN eine Funktion auf diesem Mac fehlt DANN SOLL `doctor` sie als `unsupported` mit Grund melden statt Nullwerte zu liefern | MVP | Bestand, RE/Aktivitätsanzeige §1 |
| R04 | Als Betreiber möchte ich Agenten nur begrenzt schreiben lassen | WENN ein Agent eine schreibende Aktion aufruft DANN SOLL er zuerst einen Plan mit ID und Ablauf erhalten und erst ein zweiter Aufruf mit dieser ID ausführen | MVP | RE/Burrow §2 |
| R05 | Als bestehender Nutzer möchte ich, dass meine Befehle, Felder, Pfade und Einstellungen weiter funktionieren | WENN Rust den Swift-Kern ersetzt DANN SOLLEN alle v0.12-Orakelfixtures bestehen | MVP | AGENTS.md |
| R06 | Als Nutzer möchte ich, dass die App nichts anderes zeigt als die CLI | WENN die App einen Wert zeigt DANN SOLL er aus demselben Rust-Kern stammen | MVP | AGENTS.md „GUI owns no logic“ |
| R07 | Als Nutzer möchte ich Cockpit-Aktionen in Kurzbefehlen nutzen | WENN ich Kurzbefehle öffne DANN SOLLEN Lese- und sichere Aktionen als App Intents erscheinen | Später | Ersatz für Automator |

### Monitor (Aktivitätsanzeige, Stats-Umfang, Codenotch-Anzeige)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R10 | Systemkacheln für CPU, GPU, Speicher, Swap, Speicherdruck, Netz und Disk-I/O | WENN die Zeitdifferenz nicht positiv ist oder ein Zähler zurückspringt DANN SOLL eine Lücke statt einer Spitze erscheinen | MVP | RE/Aktivitätsanzeige §2 |
| R11 | Prozessliste mit CPU, Speicher, GPU, Netz und Disk je Prozess | WENN eine PID wiederverwendet wird DANN SOLL kein alter Verlauf übernommen werden | MVP | RE/Aktivitätsanzeige §2 |
| R12 | Prozess beenden | WENN ich beende DANN SOLL das Ergebnis (beendet, läuft noch, verweigert) nachgeprüft angezeigt werden | MVP | RE/Aktivitätsanzeige §5 |
| R13 | Systemleistung getrennt von Netzteilleistung | WENN der Mac auf Akku läuft DANN SOLL die Systemleistung trotzdem einen Wert haben | MVP | #403 |
| R14 | Sensoren, Lüfter, Akku lesen | wie heute, Plausibilitätsgates bleiben | MVP | Bestand |
| R15 | Verlauf und Export | WENN der Verlauf voll ist DANN SOLL der älteste Eintrag weichen; Export als JSON und CSV | MVP | Bestand, RE/Burrow §4 |
| R16 | HUD und Notch | wie heute; ein Datenbesitzer, Anzeigezustand je Bildschirm | MVP | Bestand, RE/Codenotch §4 |
| R17 | AI-Kontingente und Agent-Sessionwechsel | WENN eine Session von „arbeitet“ zu „wartet“ oder „fertig“ wechselt DANN SOLL eine Mitteilung kommen, beim ersten Inventar keine | Später | RE/Codenotch §5, Daten aus Brain |
| R18 | Energie je Prozess | WENN angezeigt DANN SOLL sie als Schätzung mit Quelle gekennzeichnet sein | Später | RE/Aktivitätsanzeige §3 |

### Tuning (Bestand)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R20 | Lüftersteuerung über signierten Helfer | WENN der Helfer stirbt oder Temperaturen fehlen DANN SOLL die Firmware die Kontrolle zurückbekommen | MVP | #405, #414 |
| R21 | Ladegrenze | wie heute, mit Readback | MVP | Bestand |
| R22 | Wachhalten, Helligkeit, EDR, Wärme, Dimmen, Profile | wie heute, Restore-on-exit bleibt | MVP | Bestand |

### Speicher (DriveDx, Disk Speed Test, Burrow, Uninstaller)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R30 | SMART-Gesundheit interner NVMe mit Gesamtnote und Begründung | WENN ein Einzelwert kritisch ist DANN SOLL die Gesamtnote kritisch sein (Worst Case) und die Algorithmusversion gespeichert werden | Muss | RE/DriveDx |
| R31 | SMART-Verlauf und Mitteilung | WENN sich ein Wert verschlechtert DANN SOLL eine Mitteilung kommen, geplant auf festem Zeitraster | Muss | RE/DriveDx |
| R32 | Geschwindigkeitstest | WENN der Test endet DANN SOLL das Ergebnis Bytes, Dauer, MiB/s, MB/s und Cache-Modus enthalten und nur eigene Testdateien löschen | Muss | RE/Disk Speed Test §2, §3 |
| R33 | Platzanalyse | WENN ich einen Ordner analysiere DANN SOLL eine sortierte Baumansicht mit Größen erscheinen, Hardlinks einmal gezählt | Muss | RE/Burrow |
| R34 | Bereinigung nach Katalog | WENN ich bereinige DANN SOLL zuerst ein Plan mit Ablauf erscheinen; geänderte Objekte sperren den Plan; Papierkorb ist Standard | Muss | RE/Burrow §1, §3 |
| R35 | Duplikate finden | WENN Duplikate gefunden werden DANN SOLL keine Datei ohne ausdrückliche Auswahl entfernt werden | Muss | RE/Burrow |
| R36 | Platzprognose | WENN weniger als sieben Tage Verlauf vorliegen DANN SOLL keine Datumsprognose erscheinen | Später | RE/Burrow §5 |
| R37 | App deinstallieren | WENN ich eine App wähle DANN SOLL ein Plan jede Datei mit Kategorie und Zuordnungsgrund zeigen; Dokumente sind ausgeschlossen; Namensähnlichkeit allein reicht nicht | Muss | RE/Uninstaller §1 bis §4 |
| R38 | Reste bereits gelöschter Apps finden | WENN Reste gefunden werden DANN SOLL derselbe Planablauf gelten | Später | RE/Burrow |
| R39 | SMART externer USB-SATA-Laufwerke | WENN smartctl installiert ist DANN SOLL Cockpit es als externes Programm mit Timeout nutzen | Später | RE/DriveDx |

### Audio und MIDI (Audio-MIDI-Setup, Vorssaint-Mixer)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R40 | Geräte, Standard-Ein- und Ausgabe, Lautstärke | WENN ein Gerät verschwindet DANN SOLL es offline erscheinen und keine alte Objekt-ID wiederverwendet werden | Muss | RE/Audio-MIDI-Setup |
| R41 | Samplerate und Format setzen | WENN ein Setzen fehlschlägt oder der Readback abweicht DANN SOLL kein Erfolg gemeldet werden | Muss | RE/Audio-MIDI-Setup F-005 bis F-010 |
| R42 | Aggregate und Multi-Output anlegen und löschen | WENN ein Teilschritt scheitert DANN SOLL aufgeräumt und der Fehler gemeldet werden | Muss | RE/Audio-MIDI-Setup |
| R43 | MIDI-Geräte und Endpoints anzeigen | WENN ein Endpoint entfernt wird DANN SOLL die Liste sich ohne Neustart aktualisieren | Muss | RE/Audio-MIDI-Setup |
| R44 | Lautstärke und Stumm pro App | WENN das Ausgabegerät wechselt oder verschwindet DANN SOLL keine App dauerhaft stumm bleiben | Muss | RE/Vorssaint §2 |
| R45 | Ausgabegerät pro App, Netzwerk-MIDI, Surround | | Später | RE/Vorssaint, RE/Audio-MIDI-Setup |

### Bluetooth (LightBlue, Geräteakkus)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R50 | Gekoppelte Geräte mit Akkustand | WENN ein Gerät keinen Akkustand liefert DANN SOLL „unbekannt“ statt 0 % erscheinen | Muss | Stats-Umfang |
| R51 | BLE-Scan, Verbinden, Services und Characteristics lesen, abonnieren | WENN ein Filter gesetzt wird DANN SOLL er nur die Anzeige ändern, keine Verbindung trennen | Muss | RE/LightBlue |
| R52 | Characteristic schreiben | WENN geschrieben wird DANN SOLLEN Auftrag, ACK und Readback getrennt sichtbar sein | Muss | RE/LightBlue §1 |
| R53 | Log-Export | WENN exportiert wird DANN SOLL CSV nach RFC 4180 und JSON mit Rohbytes entstehen | Muss | RE/LightBlue §5 |
| R54 | Virtuelle Peripheriegeräte | | Später | RE/LightBlue §2 |
| R55 | Cloud-Weiterleitung von Messwerten | | Nie | RE/LightBlue §4 |

### Eingabe und Finder (Command X, Feel My Mac, Folder Preview, MouseBoost Pro)

| ID | User Story | Abnahme | Priorität | Herkunft |
|---|---|---|---|---|
| R60 | Finder ⌘X und ⌘V | WENN eine andere App vorne ist DANN SOLL ⌘X dort unverändert wirken | Muss | RE/Command X |
| R61 | Trackpad-Haptik und Materialklang | WENN MultitouchSupport oder ein Symbol fehlt DANN SOLL die Haptik mit benannter Fehlerstufe ausfallen, der Klang weiterlaufen und die Einstellung erhalten bleiben | Muss | RE/Feel My Mac, D09 |
| R70 | Quick Look für Ordner | WENN der Ordner sehr groß ist DANN SOLL die Vorschau ebenenweise mit Tiefenlimit laden | Muss | RE/Folder Preview |
| R71 | Quick Look für ZIP, TAR, 7z | WENN ein Archiv eine Größen- oder Eintragsgrenze überschreitet DANN SOLL die Vorschau abbrechen, ohne zu entpacken | Muss | RE/Folder Preview F-017 |
| R72 | Finder-Kontextaktionen | WENN zwei Aktionen gleichzeitig ausgelöst werden DANN SOLL keine verloren gehen oder doppelt laufen; Dateinamen bleiben Daten | Muss | RE/MouseBoost Pro §1 bis §3 |
| R73 | Zwischenablageverlauf | WENN die Funktion aus, pausiert oder die Quelle ausgeschlossen ist oder der Inhalt aus einem sicheren Feld stammt DANN SOLL nichts gespeichert werden; Löschen entfernt Metadaten und Anhänge; Agentenzugriff nach G3 | Muss | RE/MouseBoost Pro §4, RE/Vorssaint §4, D13 |

## 6. Nicht-funktionale Anforderungen

| ID | Qualität | Szenario | Priorität |
|---|---|---|---|
| Q01 | Funktionale Korrektheit | WENN ein Setzen zurückkehrt, der Zustand aber abweicht DANN SOLL das Ergebnis `unconfirmed` oder `failed` lauten | Muss |
| Q02 | Sicherheit | WENN der privilegierte Helfer einen Auftrag erhält DANN SOLL er Aufrufer-Signatur, Aktion und Parameter selbst prüfen; keine Shelltexte | Muss |
| Q03 | Sicherheit | WENN gelöscht wird DANN SOLL nur ein bestätigter, nicht abgelaufener Plan mit unveränderten Objektidentitäten ausgeführt werden | Muss |
| Q04 | Effizienz | WENN keine Ansicht einen Messwert braucht DANN SOLL er nicht gemessen werden | Muss |
| Q05 | Zuverlässigkeit | WENN Cockpit abstürzt DANN SOLLEN Lüfter, Gamma und Helligkeit beim nächsten Start auf Systemwerte zurückgesetzt werden | Muss |
| Q06 | Wartbarkeit | WENN Code Plattform-FFI braucht DANN SOLL `unsafe` nur in den Plattform-Crates stehen; alle anderen Crates verbieten es | Muss |
| Q07 | Testbarkeit | WENN Tests laufen DANN SOLL keine echte Hardware beschrieben werden; Hardwareabnahme ist getrennt und opt-in | Muss |
| Q08 | Datenschutz | WENN Cockpit läuft DANN SOLL es nichts senden außer der optionalen Updateprüfung; Prozessnamen werden standardmäßig nicht dauerhaft gespeichert | Muss |
| Q09 | Kompatibilität | WENN ein Nutzer von v0.12 aktualisiert DANN SOLLEN Einstellungen, Profile, Keychain-Einträge und Helfer-Identität erhalten bleiben | Muss |
| Q10 | Barrierefreiheit | WENN die App läuft DANN SOLL sie die Symaira Interface Guidelines samt `gui-review.py` bestehen | Muss |

## 7. Randbedingungen

| Randbedingung | Quelle |
|---|---|
| macOS arm64, Mindestversion wie heute macOS 26 | Plattformbeschluss 2026-10-29, README |
| Rust für Kern, CLI, MCP, Helfer; Swift nur für SwiftUI-App und App-Erweiterungen | Daniel |
| Apache-2.0; GPL-Originale nur als Muster | Lizenz, `candidates.json` |
| Keine kostenpflichtigen Dienste oder Modelle | Daniel |
| Produktvertrag braucht Revision 9 vor Umsetzung | PB-2026-09-09 §1, §4 |
| Bestehende Identifier nur per geprüfter Migration ändern | PB §8, AGENTS.md |
| CoreKit-Crates statt eigener MCP-, Config- oder Update-Implementierung | Ökosystemregel |

## 8. Geschäftsmodell

Entfällt: öffentliches Apache-2.0-Produkt ohne Pro-Edition (`tuning/docs/commercial-boundary.md`).

## 9. Offene Produktfragen

1. Dürfen Agenten den Zwischenablageverlauf lesen (R73, D13)? Frage an G3.
2. Welche Funktionen der Originale nutzt Daniel wirklich? Der Schnitt in 01-recherche §7 gilt als Arbeitsgrundlage, bis Daniel ihn korrigiert.
3. Bleiben Homebrew Formula (CLI) und Cask (App) getrennt, oder liefert der Cask die CLI mit? Frage an G3.

Geklärt am 2026-11-20: Zwischenablageverlauf ja (D13), Haptik ab Start (D09).

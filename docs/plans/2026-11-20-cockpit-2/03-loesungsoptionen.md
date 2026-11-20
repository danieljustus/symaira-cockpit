# Lösungsoptionen: Symaira Cockpit 2

> Status: freigegeben (2026-11-20, Daniel; G3: Option A, D14) · Basis: [02-produktbrief.md](02-produktbrief.md), [entscheidungen.md](entscheidungen.md)

## Ergebnis zuerst

**Empfehlung: Option A, „die CLI ist das Produkt“.** Ein Rust-Binary `symcockpit` ist CLI, MCP-Server und App-Agent zugleich. Die SwiftUI-App startet genau dieses Binary aus ihrem Bundle als langlebigen Kindprozess und zeigt nur, was es liefert. So arbeiten Desktop (`DeskTransport` mit Befehlen und NDJSON-Streams), Brain (`MemoryClient`) und Voice bereits. Option B (Rust als Bibliothek in der App) bleibt Rückfall, falls Spike S1 zeigt, dass ein Kindprozess die Rechte der App nicht nutzen kann.

## 1. Optionen

| Option | Kurzbeschreibung | Wiederverwendung | Wichtigstes Risiko |
|---|---|---|---|
| 0 Baseline | Originale behalten, Stats und Burrow ergänzen; Cockpit bleibt Swift und wächst nur moderat | alles Vorhandene | Verfehlt Daniels Ziele: kein Rust, kein gemeinsamer Vertrag, 16 Werkzeuge bleiben |
| A CLI ist das Produkt | `symcockpit` (Rust) mit drei Modi: Befehle, `serve` (MCP über stdio), `agent` (JSON-RPC und NDJSON-Ereignisse über stdio für die App). Die App bündelt das Binary und startet den Agent als Kindprozess für Live-Daten und rechtegebundene Funktionen. Privilegierter Helfer als Rust-Daemon über SMAppService. Quick-Look- und FinderSync-Erweiterungen als dünne Swift-Hüllen mit kleiner Rust-Bibliothek | CoreKit-Crates, Desktop-Transportmuster, Swift-Bestand als Orakel | TCC-Zuordnung des Kindprozesses (Spike S1) |
| B Rust-Bibliothek in der App | Rust-Kern per UniFFI oder swift-bridge als statische Bibliothek in App und Erweiterungen; CLI und MCP als separates Binary aus denselben Crates | wie A, plus Bindungsgenerator | Kein Präzedenzfall im Ökosystem (kein UniFFI in Brain, Desktop, Voice); xcframework-Bau; ein Rust-Fehler beendet die App; zwei Einstiegswege können auseinanderlaufen |
| C Daemon-zentriert | Dauerhaft laufender Rust-LaunchAgent `symcockpitd` besitzt allen Zustand; CLI, MCP und App sind Clients über einen Unix-Socket | wie A | Dauerläufer widerspricht Q04 und PB §7 (keine Hintergrundprozesse allein durch Installation); eigene TCC-Identität; Upgrade- und Lebenszyklusaufwand |

## 2. Bewertung

Skala: ++ sehr gut, + gut, o neutral, − schlecht. Aufwand ist eine unbelegte relative Einschätzung.

| Kriterium | Gewicht | Baseline | A | B | C |
|---|---|---|---|---|---|
| Ein Vertrag für Mensch und Agent (R06, D08) | hoch | − | ++ | + | ++ |
| Rechtegebundene Live-Funktionen: Event-Taps, Zwischenablage, Process Taps, Haptik, BLE (R44, R51, R60, R61, R73) | hoch | + | + (S1 offen) | ++ | o |
| Sicherheit und geringste Rechte (Q02, Q03, PB §7) | hoch | o | ++ | + | − |
| Testbarkeit über Drahtvertrag und Fixtures (Q07, Z5) | mittel | − | ++ | + | + |
| Effizienz (Q04, Z4) | mittel | − | + | ++ | − |
| Präzedenz und Wartung im Ökosystem | mittel | o | ++ | − | o |
| Muss-Anforderungen abgedeckt | hoch | − | ++ | ++ | ++ |
| Aufwand (relativ, unbelegt) | niedrig | ++ | o | − | − |
| Umkehrbarkeit | niedrig | ++ | + | o | − |

## 3. Wiederverwendungsleiter

| Stufe | Ergebnis |
|---|---|
| Weglassen | Automator, Cyberduck (D04, D05); Vorssaint-Fenster, Dock, Medien, Spaces; LightBlue-Cloud; Burrow-HTTP, Prometheus, SSE; DriveDx-kext und E-Mail; Videotabelle |
| Daniels Bestand | Swift-Cockpit als Paritätsorakel und Quelle der Hardware-Regeln; CoreKit `symaira-core-mcp`, `-config`, `-log`, `-exit`, `-version`, `-update`, `-sqlite`; Desktop-Transportmuster; `symbrain usage` als Datenquelle; CoreKit-AppKit-Paket für die GUI |
| Open Source als Abhängigkeit | objc2-Framework-Crates, macmon, libproc, mach2, dua-cli, czkawka_core, trash, btleplug, coremidi, zip, sevenz-rust2 (Lizenzen MIT, Apache-2.0, BSD, Zlib; siehe `candidates.json`) |
| Fork | keiner |
| Plattformfunktion | SMAppService, XPC mit Peer-Signaturprüfung, Quick Look, FinderSync, UserNotifications, `pkgutil`, später App Intents |
| Eigener Minimalcode | SMC-Port, NVMe-Health-Regeln, Bereinigungskatalog, Besitzplan für Deinstallation, Mixer, Finder-⌘X-Tap, Haptik-Loader, Zwischenablagespeicher, Planbestätigung |

## 4. Symaira-Einordnung

- **Besitz:** Spur A, Cockpit. Produktvertrag Revision 9 nach G5 (D02).
- **Abgrenzung zu Scope:** Ressourcen je Prozess (CPU, Speicher, GPU, Netz, Disk) liegen in Cockpit; Ports, Container, Daemons und MCP-Inventar bleiben in Brain Scope.
- **Abgrenzung zu Operate:** Finder-⌘X und Haptik sind vom Menschen ausgelöste Eingabeflächen, keine Agentenautomation. Analog zur Diktatregel für Desktop (PB Revision 7) darf kein MCP-Tool synthetische Eingaben oder Haptik auslösen. Fensteraktionen bleiben Operate.
- **Zwischenablage:** PB §4 sagt, Codeumzüge erlauben keine Zwischenablageerfassung für Agenten. Der Verlauf ist ein Werkzeug für den Menschen; ob und wie Agenten lesen dürfen, entscheidet G3.
- **Kits:** Plattform-Crates bleiben produkteigen. Erst wenn ein zweites Produkt dieselbe Semantik braucht, gehört etwas nach CoreKit (PB §5).

## 5. Empfehlung und verworfene Optionen

- **Empfehlung A**, weil sie den Vertrag „App zeigt nichts, was die CLI widerlegt“ technisch erzwingt, Tests auf einen Drahtvertrag konzentriert, dem Vorgehen von Desktop, Brain und Voice folgt und keine Dauerläufer einführt. Der Agent läuft nur, solange die App läuft; ohne App bleibt Cockpit eine reine CLI mit MCP.
- **B zurückgestellt:** technisch stark bei Rechten und Effizienz, aber ohne Präzedenz im Ökosystem und mit doppeltem Einstieg. Rückfall, falls S1 scheitert, dann nur für die rechtegebundenen Funktionen.
- **C verworfen:** Ein ständiger Hintergrunddienst widerspricht den geringsten Rechten und Q04. Der einzige Dauerdienst bleibt der privilegierte Lüfterhelfer, und auch der nur, solange Lüftersteuerung aktiv ist (#405).
- **Baseline verworfen:** erfüllt weder Rust-Vorgabe noch Ersatzziel Z1.

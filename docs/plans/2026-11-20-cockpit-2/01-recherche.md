# Recherche: Symaira Cockpit 2

> Status: freigegeben (2026-11-20, Daniel; G1: weiter mit angepasstem Umfang) · Abruf: 2026-11-20 · Quellen: [research/SOURCES.md](research/SOURCES.md) · Kandidaten: [research/candidates.json](research/candidates.json) (58 Einträge: 16 RE-Analysen, 4 Symaira, 38 Open Source)

## Ergebnis zuerst

**Urteilsvorschlag: anpassen, dann weiter.** Ein Rust-Neuaufbau ist machbar: Für jede benötigte Apple-Schnittstelle gibt es Rust-Bindings, NVMe-SMART und Process Taps sind öffentliche SDK-Schnittstellen. Drei der 16 Werkzeuge gehören aber nicht in Cockpit: **PDF Squeezer** gehört zu Desktop (dort existiert bereits eine Rust-PDF-Engine), **Automator** und **Cyberduck** haben keinen Bezug zur Mac-Hardware. Der größte Einwand ist der Umfang: Jedes Original ist ein eigenes Produkt. Ein Ersatz lohnt sich nur mit hartem Funktionsschnitt (Abschnitt 7) und einer Erweiterung des Produktvertrags.

## 1. Daniels Bestand

### 1.1 Reverse Engineering (alle statisch analysiert, keine Laufzeittests)

| Original (Version) | Kern des Originals | Übertragbare Muster | Ziel |
|---|---|---|---|
| Apple Aktivitätsanzeige (10.14_1040) | Prozess- und Systemmessung, Prozessaktionen über Helfer | Messung nur nach Bedarf, monotone Zeitbasis, Zählerrücksprung als Lücke, PID-Wiederverwendung, typisierte Helferaktion, bestätigter Toolabschluss | Cockpit Monitor |
| Apple Audio-MIDI-Setup (3.9) | Audiogeräte, Format, Clock, Aggregate, Process Taps, MIDI-Studio | Geräte-UID getrennt von HAL-Objekt-ID; Erfolg erst nach OSStatus und Readback; Listener statt Polling; Kanalplan vorab prüfen | Cockpit Audio |
| Blackmagic Disk Speed Test (3.4.3) | Sequenzieller Schreib-/Lesetest, Videotabelle, CLI | Messkern ohne UI; MiB/s und MB/s explizit (Original zeigt MiB/s als „MB/s“, F-007); Cache-Schalter prüfen; Dateibesitz statt Namens-Cleanup | Cockpit Speicher |
| Burrow (0.14.0, MIT) | Bereinigung, App-Verwaltung, Plattenanalyse, Status, Prognose, MCP und HTTP | Ablaufender Auswahlauftrag; Ergebnis als Nachbedingung (entfernt, vorhanden, ungewiss); SQLite-Leser ohne Reparaturrechte; Prognose erst ab sieben Tagen Basis | Cockpit Speicher und Monitor |
| Codenotch (1.24.0, MIT) | Kontingente von Coding-Agenten in der Notch, Session-Meldungen | Generationen gegen späte Antworten; Messwert, Frische und Zugriffsrecht trennen; Übergänge statt Zustände melden | Anzeige in Cockpit, Daten aus Brain |
| Command X (1.7.1) | Finder ⌘X/⌘V per synthetischem Tastaturevent | Frontmost-Gate mit Weiterleitung des Originalevents; Zustand im Pasteboard; Rechte-Dialog mit Deeplink | Cockpit Eingabe |
| Uninstaller (1.1.0) | Bundle plus abgeleitete Pfade löschen, Admin-Shelltext | Negativbeispiel: Namensähnlichkeit ist kein Besitz (F-007, F-014); Verbesserung: Plan mit Kategorie und Grund, Papierkorb, Einzelresultate | Cockpit Speicher |
| DriveDx (1.12.1) | SMART über IOKit, smartctl und kext; Health-Regeln, Berichte | Gesamtnote als Worst Case; Bewertung mit Algorithmusversion; Ideal-Zeitraster; Subprozess mit Timeout | Cockpit Speicher |
| Feel My Mac (1.0.4) | Trackpad-Haptik und Materialklang | Fähigkeitsabhängige Degradation mit Fehlerstufen; Monitore nur bei Bedarf. Haptik nur über privates MultitouchSupport (F-010) | Cockpit Eingabe, nur nach Spike |
| Folder Preview (3.1.1) | Quick Look für Ordner und Archive | Ebenenweises Laden mit Tiefenlimit; Archive wie Ordner darstellen. Nicht übernehmen: Vollentpackung ohne Größengrenze (F-017) | Cockpit Finder |
| LightBlue (5.3.6) | BLE-Scanner, GATT, virtuelle Peripherie, CSV, Cloud | Auftrag, ACK und Readback getrennt; Backpressure als Zustand; versionierte Profile; RFC-4180-CSV | Cockpit Bluetooth |
| MouseBoost Pro (5.3.0) | Finder-Kontextmenü, Dateiaktionen, Skripte, Zwischenablage, HTTP-Freigabe | Auftrag mit ID, Ablauf und Quittung; Dateinamen bleiben Daten; Zwischenablage filtern vor Persistenz | Cockpit Finder |
| PDF Squeezer (4.9) | PDF-Kompression, zwei Engines, 46 Profilattribute | Engine-unabhängiger Auftrag mit Capability-Prüfung; Original bis zum Commit behalten (F-017, F-018) | Desktop |
| Vorssaint (3.4.4, GPL-3.0) | Menüleisten-Hub: Mixer, App-Wechsler, Dock-Vorschau, Zwischenablage, Lüfter, Medien | Verfügbarkeit, Aktivierung und Freigabe getrennt; Audioumschaltung mit Rückfall | nur Mixer in Cockpit Audio |
| Apple Automator (2.10) | Workflow-Editor mit typisierten Actions | Typverträge je Schritt; Prozesskanäle getrennt | nicht nachbauen |
| Cyberduck (9.3.1, GPL-3.0) | FTP, SFTP, WebDAV, S3 und mehr; Cryptomator | Capability-Interfaces; Profile als Daten; persistente Queue | nicht nachbauen |

Quelle je Zeile: `RE/<Anwendung>/rebuild.md` und `report.md` §2 bis §5. Befund-IDs verweisen auf das jeweilige `findings.md`.

### 1.2 Symaira-Bestand

| Bestand | Was es schon kann | Lücke zur Idee |
|---|---|---|
| Cockpit v0.12.2 (Swift 6) | Sensoren, Lüfter, Ladegrenze, Wachhalten, Helligkeit, EDR, Wärme, Dimmen, Profile, Verlauf, Top-Prozesse, HUD/Notch, AI-Kontingente; 26 MCP-Tools, davon 12 lesend (`get_status`, `get_sensors`, `get_battery`, `get_system_metrics`, `get_top_processes`, `get_history` u. a.) | Swift statt Rust; kein Speicher-, Audio-, Bluetooth- oder Finderbereich; #418 Dauer-CPU-Last der App |
| CoreKit (Rust 1.98, Edition 2024) | `symaira-core-mcp`, `-config`, `-log`, `-exit`, `-version`, `-update`, `-sqlite`, `-fs`, `-env`, `-secretref`, `-mcpcfg`, `-llm` | Keine Plattform- oder Hardware-Crates (bewusst domänenfrei) |
| Desktop `symdesk-render` | Rust-PDF mit lopdf 0.47: Split, Merge, Rotate, Bildimport (PNG, TIFF, Fax) | Keine Kompression |
| Brain `symbrain-usage`, Scope | Nutzungsdaten der Harnesses; Scope: Ports, Container, launchd, MCP-Inventar | Keine Session-Statusmeldungen für die Notch |
| Voice | Muster „CLI ist das Produkt“, App ohne Logik, Swift-Worker nur wo nötig, `unsafe` verboten | Cockpit braucht FFI zu IOKit und Co., also `unsafe` an einer engen Stelle |

## 2. Originale

Alle 16 Originale sind auf dem Mac installiert oder Systemapps (`ls /Applications`, 2026-11-20). Preise und Abo-Modelle wurden nicht erhoben. Belegt sind kostenpflichtige Lizenzmechanismen in DriveDx (AquaticPrime), Feel My Mac (ES256-Token), MouseBoost Pro und Folder Preview (MAS-Receipt) laut den jeweiligen RE-Berichten. Wichtigster offener Vergleich: Burrow ist bereits ein freies Komplettwerkzeug für Bereinigung, App-Verwaltung, Plattenanalyse und Status mit MCP.

## 3. Open Source (Auswahl, vollständig in `candidates.json`)

| Repo oder Crate | Lizenz | Aktivität | Entscheidung | Grund |
|---|---|---|---|---|
| objc2 + Framework-Crates (IOKit, CoreAudio, CoreMIDI, CoreBluetooth, ServiceManagement, PDFKit, QuickLookUI, FinderSync) | Zlib OR Apache-2.0 OR MIT | 0.3.2, 2025-10-04; objc2 0.6.5, 2026-10-05 | Abhängigkeit | Deckt alle nötigen Frameworks ab |
| macmon | MIT | 0.12.0, 2026-11-15 | Abhängigkeit (Spike S2) | Leistung und Frequenzen ohne sudo über IOReport |
| libproc, mach2 | MIT, BSD/MIT/Apache | 2026-11, 2026-08 | Abhängigkeit | Prozesse und Hoststatistik |
| dua-cli | MIT | 3.0.3, 2026-11-12 | Abhängigkeit | Schnelle Platzanalyse |
| czkawka_core | MIT | 12.0.2, 2026-09-09 | Abhängigkeit | Duplikate, leere Ordner, große Dateien |
| trash | MIT | 5.4.0, 2026-11-17 | Abhängigkeit | Papierkorb statt Löschen |
| btleplug | MIT/Apache/BSD | 0.13.5, 2026-10-10 | Abhängigkeit | BLE-Central; Peripherie über objc2 |
| coremidi | MIT | 0.9.2, 2026-08-02 | Abhängigkeit | MIDI |
| lopdf, jpeg-encoder, zune-jpeg | MIT bzw. MIT/Apache(/IJG) | 2026-11 | Abhängigkeit (Desktop) | PDF-Kompression |
| Stats, Burrow, Codenotch | MIT | aktiv, 2026-11 | Muster | Funktionsumfang und Abläufe; Swift |
| Vorssaint, Mole, iSMC, Cyberduck | GPL-3.0 | aktiv | nur Muster bzw. verwerfen | GPL verträgt sich nicht mit Apache-2.0-Code |
| smartmontools | GPL-2.0 | aktiv | beobachten | Höchstens als zur Laufzeit gefundenes externes Programm |
| Pearcleaner, AlDente | keine OSI-Lizenz | aktiv | verwerfen | Kein Nutzungsrecht am Code |
| rmcp | Apache-2.0 | aktiv | verwerfen | Ökosystem nutzt CoreKit-MCP |

## 4. Machbarkeit

| Bereich | Befund | Typ | Quelle |
|---|---|---|---|
| NVMe-SMART | `IONVMeSMARTInterface` mit `SMARTReadData`, `GetIdentifyData`, `GetLogPage` liegt als öffentlicher Header im macOS-SDK (`IOKit/storage/nvme/NVMeSMARTLibExternal.h`) | Beobachtung | lokales Xcode-SDK |
| ATA-SMART | `ATASMARTLib.h` öffentlich; USB-SATA-Brücken brauchen SAT-Passthrough, der kext-Weg gilt als veraltet | Beobachtung, Inferenz | SDK; RE/DriveDx/rebuild.md |
| Process Taps (Mixer) | `AudioHardwareCreateProcessTap`, `API_AVAILABLE(macos(14.2))` | Beobachtung | SDK `AudioHardwareTapping.h` |
| XPC-Helfer | `xpc_connection_set_peer_code_signing_requirement`, macOS 12.0, C-API; aus Rust direkt aufrufbar | Beobachtung | SDK `xpc/connection.h` |
| SMC | Undokumentierter IOKit-User-Client; Cockpit nutzt ihn heute schon samt Endianness- und Plausibilitätsregeln | Beobachtung | `tuning/AGENTS.md` |
| IOReport (Leistung, Frequenzen) | `libIOReport.tbd` im SDK, aber kein öffentlicher Header; macmon liest ohne sudo | Beobachtung | SDK `usr/lib`; macmon README |
| GPU-Auslastung | `IOAccelerator` `PerformanceStatistics` ohne root lesbar (live geprüft 2026-11-10) | Beobachtung | Adoptionsbericht Vorssaint |
| Trackpad-Haptik | Nur privates MultitouchSupport per dlopen; öffentlich nur Standardmuster über `NSHapticFeedbackManager` | Beobachtung | RE/Feel My Mac F-010 |
| Bluetooth-Recht für CLI | CoreBluetooth verlangt eine Zweckangabe im Info.plist; eine nackte CLI erbt die Freigabe des startenden Terminals | Annahme | Spike S1 |
| Accessibility für Event-Taps | TCC bindet die Freigabe an die signierte Identität; ob ein Rust-Helfer im App-Bundle die App-Freigabe nutzt, ist ungeprüft | Annahme | Spike S1 |
| App-Erweiterungen | Quick Look und FinderSync brauchen `.appex`-Bundles; Rust kann die Logik als Bibliothek liefern | Inferenz | RE/Folder Preview, RE/MouseBoost Pro |
| Vertrieb | Kein Mac App Store (SMC, globale CLI, undokumentierte APIs); notarisierter Direktvertrieb und Homebrew wie heute | Beobachtung | `tuning/AGENTS.md`, `.github/workflows/release.yml` |
| Lizenz | Apache-2.0 bleibt; GPL-Originale nur als Muster | Beobachtung | Lizenzfelder in `candidates.json` |
| Kosten | Keine laufenden Dienste; Apple Developer Account für Notarisierung existiert bereits | Beobachtung | Release-Workflow, Umgebung `release` |

## 5. Nutzerstimmen

Nicht systematisch erhoben. Daniels eigener Bedarf ist der Treiber. Schwaches Nachfragesignal: hohe GitHub-Sternzahlen freier Alternativen (Mole 75.691, Stats 43.530, Vorssaint 35.440, czkawka 35.358; Stand 2026-11-20). Das belegt Interesse an solchen Werkzeugen, aber auch starke kostenlose Konkurrenz.

## 6. Was gegen die Idee spricht

- **Umfang:** 16 Originale, darunter Werkzeuge mit langer Entwicklungsgeschichte (DriveDx mit Regelwerk und Algorithmusversionen; Cyberduck mit 39 eigenen Modulen, RE/Cyberduck §2).
- **Freie Konkurrenz:** Stats (MIT) plus Burrow (MIT) decken Monitor, Bereinigung, App-Verwaltung und einen MCP-Zugang bereits weitgehend ab. Die Baseline „nutzen statt bauen“ ist realistisch.
- **Rewrite-Risiko:** 33.410 Zeilen funktionierender Swift-Code tragen teuer gelernte Hardware-Regeln (SMC-Byteordnung #185, M4-Pro-Sensoren `Tp01` bis `Tp09`, Gamma-Besitz). Ein Neuaufbau kann sie verlieren, wenn keine Paritätsfixtures existieren.
- **Undokumentierte Schnittstellen** (SMC, IOReport, IOAccelerator-Schlüssel, MultitouchSupport) können mit jedem macOS-Update brechen.
- **Produktvertrag:** Revision 8 begrenzt Cockpit eng; PDF gehört Desktop, Maschinendiagnostik Scope.
- **Agentensicherheit:** Bereinigen, Deinstallieren, Lüfter und Ladegrenze sind destruktiv oder hardwarenah. Ohne Plan-und-Bestätigung wäre ein MCP-Zugang gefährlich (Burrow trennt GUI-Snapshot und MCP-Pfad nicht gleich streng, RE/Burrow features/bereinigung.md).
- **TCC-Identität:** Bluetooth, Bedienungshilfen und Bildschirmaufnahme sind an signierte App-Identitäten gebunden; eine reine Rust-CLI stößt hier an Grenzen.

## 7. Wie komplex muss der Ersatz sein?

Antwort auf Daniels Frage am Beispiel PDF Squeezer: **Nein, mehrere Kompressionsengines braucht es nicht.** PDF Squeezer kombiniert einen eigenen Bildpfad mit einem eingebetteten PDF-SDK (RE/PDF Squeezer report.md §3). Für das übliche Ziel, PDFs für Mail oder Upload zu verkleinern, genügt eine Rust-Pipeline. Dass Bilddaten den Großteil typischer Scan- und Foto-PDFs ausmachen, ist eine Inferenz; Spike S7 belegt oder widerlegt sie an einem Korpus.

| Original | Was der Ersatz braucht | Was entfällt oder später kommt |
|---|---|---|
| PDF Squeezer | Bilder auf Ziel-DPI herunterrechnen und neu kodieren (JPEG für Farbe und Graustufen, verlustfrei für Schwarzweiß), Streams neu komprimieren, ungenutzte Objekte, Vorschaubilder und Metadaten entfernen; drei Stufen plus eigene DPI und Qualität; Größe vorher/nachher; Original bis zum Commit erhalten | Zweite Engine, 46-Optionen-Profile, PDF/A, Schriftoptimierung, JBIG2 (später) |
| DriveDx | Interne NVMe über die öffentliche SMART-Schnittstelle; kleine versionierte Regeltabelle nach NVMe-Health-Log (Critical Warning, Available Spare, Percentage Used, Media Errors, Temperatur); Verlauf; Mitteilung bei Verschlechterung | kext, Qt-Oberfläche, E-Mail-Berichte, ATA-Attributdatenbank; USB-SATA nur später über ein installiertes smartctl |
| Disk Speed Test | Ein sequenzieller Schreib- und Lesetest mit wählbarer Größe, MiB/s und MB/s, Cache-Modus, eigener Sitzungsordner, JSON-Ergebnis | Videotabelle; 4K-Zufallstest später |
| Burrow | Platzanalyse, Bereinigungskatalog (Caches, Logs, Xcode, Homebrew, Paketmanager, Projekt-Artefakte), Duplikate, Verlauf mit Prognose, Plan mit Ablauf, Papierkorb | HTTP-Server, Prometheus, SSE, Telemetrie, KI-Zugangsdaten, gebündelte Fremd-Engine |
| Uninstaller | Zuordnung über Bundle-ID und Team-ID in bekannten Library-Orten, Receipts über `pkgutil`, Plan mit Kategorie und Grund, Papierkorb, Einzelresultate | Admin-Shelltext, Namensheuristik als Löschgrund, eigener Updater |
| Aktivitätsanzeige | Prozessliste (CPU, Speicher, GPU, Netz, Disk), Systemkacheln, Beenden mit Bestätigung | Apple-private Energie-Scores; Energie pro Prozess nur als ausgewiesene Schätzung (später) |
| Audio-MIDI-Setup | Geräte, Standard-Ein- und Ausgabe, Samplerate und Format mit Readback, Lautstärke, Aggregate und Multi-Output, MIDI-Geräteliste | Surround-Zuordnung, Netzwerk-MIDI, Bluetooth-MIDI-Fenster (das System liefert es) |
| Vorssaint | Lautstärke und Stummschaltung pro App über Process Taps | App-Wechsler, Dock-Vorschau, Fensteraktionen, Medien (privat), Spaces, eigener Lüfter |
| LightBlue | Scan, Verbinden, Services, Lesen, Schreiben mit ACK und Readback, Abonnieren, Log-Export | Cloud-Weiterleitung; virtuelle Peripherie später |
| Codenotch | Kontingente zeigt Cockpit schon; neu sind Session-Wechsel als Mitteilung und mehrere Bildschirme. Daten liefert Brain | Eigene Log-Parser und Kostenindex in Cockpit |
| Command X | Finder ⌘X/⌘V mit Frontmost-Gate | Sound-Optionen, iCloud-Sync |
| MouseBoost Pro | Wenige Finder-Aktionen: neue Datei aus Vorlage, Pfad kopieren, im Terminal öffnen, kopieren/verschieben nach, Prüfsumme | HTTP-Freigabe, Skriptkatalog, Lizenz; Zwischenablage gesondert entscheiden |
| Folder Preview | Quick Look für Ordner sowie ZIP, TAR, 7z mit Tiefen- und Größenlimit; Archive nur auflisten statt entpacken | RAR, iCloud-Sync |
| Feel My Mac | Erst nach Spike; nur Direktvertrieb | Lizenz, Materialbibliothek |
| Automator | Nicht nachbauen; Cockpit-Funktionen als Kurzbefehle-Aktionen anbieten | Workflow-Editor |
| Cyberduck | Nicht nachbauen; rclone (MIT) oder Finder nutzen | alles |

## 8. Lücke und Differenzierung

Kein geprüftes Werkzeug vereint Hardware-Tuning, Monitor, Speicherzustand, Audio/MIDI und Bluetooth hinter **einem** stabilen JSON- und MCP-Vertrag. Nachweisbar besser als die Originale wären laut RE-Befunden: bestätigte Ergebnisse statt „Setter kehrt zurück“ (Audio-MIDI-Setup F-005 bis F-010, LightBlue F-006 bis F-009), Besitzpläne statt Namensheuristik (Uninstaller, Disk Speed Test), atomarer Export (PDF Squeezer F-017) und ehrliche Einheiten (Disk Speed Test F-007). Annahme: Diese Qualität ist Daniel den Aufwand wert.

## 9. Bewertung

| Kriterium | Bewertung | Begründung |
|---|---|---|
| Problem | ausreichend | 16 Einzelwerkzeuge mit eigenen Helfern, Lizenzen und Rechten; kein gemeinsamer Agentenzugang |
| Bestand reicht nicht | ausreichend | Stats und Burrow decken viel ab, aber nicht Audio, Bluetooth, SMART und keinen gemeinsamen Vertrag |
| Differenzierung | ausreichend | Ein Vertrag für Mensch und Agent, bestätigte Ergebnisse, lokal, keine Telemetrie |
| Machbarkeit | stark für Monitor, Speicher, Audio, Bluetooth; schwach für Haptik | Öffentliche APIs vorhanden; Haptik nur privat |
| Nutzen zu Aufwand | unbekannt | Neuaufbau ist teuer; Nutzen entsteht stufenweise |
| Evidenzstärke | ausreichend | Statische RE, SDK-Header lokal geprüft; keine Laufzeitmessungen |

## Spike-Kandidaten für Phase 5

S1 TCC-Identität eines Rust-Helfers im App-Bundle (Bluetooth, Bedienungshilfen) · S2 IOReport ohne root auf M4 Pro und macOS 27.2 · S3 NVMe-SMART aus Rust · S4 Process Tap aus Rust · S5 SMC-Port gegen Swift-Orakel · S6 Quick-Look-Erweiterung mit Rust-Bibliothek · S7 PDF-Korpus: Kompressionsquote gegen PDF Squeezer

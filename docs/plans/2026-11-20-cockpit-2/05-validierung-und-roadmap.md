# Validierung und Roadmap: Symaira Cockpit (Rust-Neuaufbau)

> Status: freigegeben (2026-11-20, Daniel; G5: „Architektur freigeben, als Nächstes Spikes S1 bis S6“) · Basis: [04-architektur.md](04-architektur.md)

## Ergebnis zuerst

Größtes Risiko ist, ob der Rust-Agent als Kindprozess die Rechte der App nutzen darf (K1). Darum steht Spike S1 vor allem anderen, gefolgt vom SMC-Port (S5). Die erste allein nützliche Stufe bringt Monitor-Daten aus Rust über CLI und MCP; nicht portierte Befehle reicht der neue Rust-Dispatcher bis zur Parität an das bisherige Swift-Binary weiter. Danach folgt je Stufe ein Bereich, der jeweils konkrete Originale ersetzt. Aufwände sind bewusst nicht geschätzt.

## 1. Spikes

Alle Spikes laufen in Wegwerf-Code außerhalb des Produkts (Ablage nach `Dev/Verwaltung/ABLAGEREGELN.md`), auf Daniels MacBook M4 Pro mit macOS 27.2, ohne Nutzerdaten.

| ID | Frage | Kleinster reversibler Test | Erfolgskriterium | Abbruchkriterium | Risiko |
|---|---|---|---|---|---|
| S1 | Nutzt ein Rust-Kindprozess die TCC-Rechte der signierten App? | Signierte Test-App startet Rust-Binary aus dem Bundle: CGEvent-Tap, CoreBluetooth-Scan, Process Tap, MultitouchSupport-Callback | Alle vier laufen mit der Freigabe der App, ohne zweite Freigabe für das Binary | Eine Funktion verlangt eine eigene Identität: nur diese wechselt in eine Rust-Bibliothek in der App | K1 |
| S2 | Liefert IOReport (macmon) ohne root brauchbare Leistungs- und Frequenzwerte? | macmon-Bibliothek 60 s neben `powermetrics` (root) | Mittelwerte von CPU-, GPU- und ANE-Leistung innerhalb ±10 % | Keine Werte oder über ±25 %: Leistung nur über SMC und IORegistry | K3 |
| S3 | Ist NVMe-SMART aus Rust ohne root lesbar? | `IONVMeSMARTInterface` öffnen, Health-Log der internen SSD lesen | Felder stimmen mit `smartctl -a` oder `system_profiler SPNVMeDataType` überein | Nur mit root: neue typisierte Helfer-Aktion `read_smart` | K3 |
| S4 | Funktioniert der Mixer aus Rust ohne dauerhafte Stille? | Process Tap auf eine Test-App, 50 % Lautstärke, Ausgabegerät während des Taps wechseln, Tap entfernen | Ton kehrt nach Entfernen zurück, kein Tap bleibt aktiv | Absturz oder bleibende Stille: Mixer in eine spätere Stufe | K7 |
| S5 | Liest der Rust-SMC-Port dieselben Werte wie Swift? | Alle in v0.12 genutzten SMC-Schlüssel parallel lesen; Lüftermodus nur in opt-in Hardware-Abnahme mit Restore | 100 % gleiche Schlüssel und Typen, Werte innerhalb des Messrauschens | Ungeklärte Abweichung: Swift-SMC bleibt bis zur Klärung | K2 |
| S6 | Lassen sich Quick-Look- und FinderSync-Erweiterung mit Rust-Bibliothek ohne Xcode-Projekt bauen und signieren? | Skript baut beide `.appex`, bettet `libsymcockpit_ffi.a` ein, signiert, `pluginkit -m` zeigt sie | Vorschau eines ZIP und eines Ordners erscheint; Finder-Menü erscheint | Skript scheitert: XcodeGen-Projekt nur für die Erweiterungen | K5 |
| S8 | Wie setzt Cockpit die Ladegrenze auf Firmware ohne SMC-Ladeschlüssel? (Befund aus S5) | Lesend: `pmset -g battlimit`, `CHIE` lesen, Vorhandensein der Ladegrenzen-Schnittstelle von macOS prüfen. Schreibend nur in opt-in Abnahme mit Daniel: Grenze 80 % setzen, ablesen, aufheben | Grenze greift ohne SMC-Schreibzugriff, Aufheben stellt den Ausgangszustand her | Keine nutzbare Schnittstelle: Ladegrenze als `unsupported` melden, nur Anzeige | K11 |
| S7 | Reicht eine Rust-Pipeline für PDF-Kompression? (Desktop, D03) | Von Daniel freigegebener Testkorpus aus Scans, Fotos und Text-PDFs gegen PDF Squeezer Standardprofil | Median-Reduktion mindestens 80 % derjenigen von PDF Squeezer bei visuell gleichwertiger Qualität | Deutlich schlechter: zweite Technik gezielt prüfen, nicht pauschal mehrere Engines | Desktop |

### Ergebnisse

**S5 bestanden, nur für diese Maschine (2026-11-20).** Rust liest ohne root und ohne Crates dieselben 64 Schlüssel wie v0.12.2: 0 Abweichungen bei Existenz, Typ und Größe in 3 Runden, dieselbe Menge aller 3374 Schlüssel. Zwei Wertzeilen außerhalb der Toleranz sind Zeitrauschen der SMC (Gegenprobe: je 40000 gleichzeitige Lesungen, 98 bis 99 % gleicher Rohwert). Bericht: `Dev/evidence/symaira-cockpit/cockpit2-spikes/S5/REPORT.md`.

- Rohe IOKit-Bindings genügen (D07); `io-kit-sys` oder `objc2-io-kit` sind für den Lesepfad nicht nötig.
- Offen: andere Chipgenerationen, `sp78` und `fpe2` live, der Schreibpfad (opt-in Hardware-Abnahme in Stufe 2).
- Befund: `FS!` ist in v0.12 nie adressierbar, weil `smcEncodeKey` Schlüssel mit 3 Zeichen auf 0 abbildet. Betrifft nur x86_64-Zweige ([#421](https://github.com/danieljustus/symaira-cockpit/issues/421)); der Rust-Port lässt den Pfad weg (D16, bestätigt).
- Befund: Die Ladegrenzen-Schlüssel `CHTE`, `CH0B`, `CH0C`, `CHLC` fehlen unter macOS 27.2.1. Externe Berichte nennen dasselbe für die Firmware von macOS 27 und 26.7; verbleibender Weg ist die Ladegrenze von macOS selbst (`powerd`, Systemeinstellungen > Batterie), `CHIE` nur für erzwungenes Entladen (Quellen E5 bis E7). v0.12 schickt den Nutzer trotzdem zu `sudo` ([#420](https://github.com/danieljustus/symaira-cockpit/issues/420)). Neuer Spike S8, Risiko K11.

**S3 teilweise bestanden (2026-11-20).** Das Health-Log der internen und der externen NVMe ist ohne root lesbar; die Helfer-Aktion `read_smart` entfällt. Modell, Firmware und SMART-Status stimmen mit `system_profiler` überein. Für die Zahlenwerte gibt es keine unabhängige Referenz, weil `smartctl` fehlt. Bericht: `Dev/evidence/symaira-cockpit/cockpit2-spikes/S3/REPORT.md`.

- Reihenfolge im Adapter: lesen, `Release`, dann `IODestroyPlugInInterface`; sonst `MACH_SEND_INVALID_DEST`.
- Die Regeltabelle v1 aus dem Bericht ist Ausgangspunkt der SMART-Note. Apple meldet als Reserve-Schwelle 99, darum ist nur „Reserve unter Schwelle“ kritisch.
- Offen vor Stufe 3: Zahlenabgleich gegen `smartctl` (Installation von smartmontools braucht Daniels Freigabe). Verhalten im App-Bundle und im Daemon prüft S1.

**S8 lesender Teil bestanden (2026-11-20).** Ohne root antwortet die private Klasse `PowerUISmartChargeClient` (Gegenstelle ist der root-Daemon `PowerUIAgent`): Ladegrenze unterstützt, wählbar 80 bis 100 % in 5er-Schritten, derzeit nicht aktiv. `CHIE` ist ohne root lesbar; `bfD0`, `bfE0`, `bfF0` verweigern schon die Typabfrage (`kIOReturnNotPrivileged`). Ob Setzen ohne root geht, klärt der Schreibtest mit Daniel. Vorläufige Folge für die Architektur: Mechanismus nach Vorhandensein (`CHTE` über den Helfer, sonst Ladegrenze von macOS, sonst `unsupported`); für die macOS-Ladegrenze voraussichtlich kein Helfer. Bericht: `Dev/evidence/symaira-cockpit/cockpit2-spikes/S8/REPORT.md`.

**Vorbereitet für die Sitzung mit Daniel (2026-11-20):** S1, S2, S4, S6 und S8 sind gebaut, signiert und statisch geprüft; keiner lief bisher mit Freigaben. S2 lief ohne root 60 s mit plausiblen Werten (macmon 0.12 als Bibliothek, kein eigenes `unsafe`). S6 baut beide Erweiterungen per Skript ohne Xcode-Projekt; das Abbruchkriterium trat beim Bau nicht ein. Ablauf: `Dev/evidence/symaira-cockpit/cockpit2-spikes/SITZUNG.md`.

## 2. Gates statt Kalender

| Gate | Arbeit | Ergebnis | Status |
|---|---|---|---|
| G0 | Recherche und Planung | Freigegebene Architektur | ✅ 2026-11-20 |
| G1 | Spikes S1 bis S6 und S8 | Belege zu K1, K2, K3, K5, K7, K11 | läuft: S3 ✅ teilweise, S5 ✅ |
| G2 | Stufe 0 und 1 | Vertrag Revision 9, Orakel, Monitor aus Rust | offen |
| G3 | Stufe 2 | Cockpit komplett in Rust, Swift-Kern entfernt | offen |
| G4 | Stufen 3 bis 6 | Bereich für Bereich, Originale ersetzt | offen |

## 3. Stufen

### Stufe 0: Fundament

- Liefert: Produktvertrag Revision 9 (kanonisch plus byte-gleiche Snapshots), Rust-Workspace mit `symcockpit-contract`, `-core`, `-macos`, `-testkit`, `-store` und CoreKit-Pins, eingefrorene v0.12-Orakel (Schemas, `tools/list`, Exit-Codes, Dateiformate, Testvektoren), CI für Rust in `scripts/ci-changed-areas.sh`.
- Nutzen allein: Der Swift-Vertrag ist erstmals maschinell eingefroren und schützt auch das laufende Produkt.
- Abnahme: Orakel-Tests laufen grün gegen Swift v0.12.

### Stufe 1: Lesepfad und Monitor aus Rust

- Liefert: Rust-Dispatcher `symcockpit` mit allen Lesebefehlen und den 12 MCP-Lesetools aus v0.12 (26 Tools insgesamt, Korrektur 2026-11-20 nach Orakel-Aufnahme); nicht portierte Befehle werden an das gebündelte Swift-Binary weitergereicht. Neu: GPU aus der IORegistry ohne root, Systemleistung getrennt vom Netzteil (#403), Prozessliste mit Netz und Disk, Prozess beenden über Plan.
- Anforderungen: R01 bis R05, R10 bis R15.
- Abnahme: Orakel grün für alle Lesebefehle; neue Tools mit Schema-Snapshot; Lücken- und PID-Tests.
- Ersetzt: Aktivitätsanzeige für Agenten und im Terminal.

### Stufe 2: Schreibpfad, Helfer, App auf Rust

- Liefert: Lüfter über den Rust-Helfer mit Heartbeat und Rückfall (#405, #414), Ladegrenze, Wachhalten, Helligkeit, EDR, Wärme, Dimmen, Profile, Restore. Die App startet den Agent und zeigt nur noch dessen Daten; HUD und Notch bleiben. Swift-Kern wird entfernt.
- Anforderungen: R06, R16, R20 bis R22.
- Abnahme: alle Orakel grün; Hardware-Matrix opt-in bestanden; App im Leerlauf ≤ 1 % CPU (Z4, #418); Upgrade von v0.12 ohne Verlust von Einstellungen, Profilen, Keychain und Helfer-Freigabe; Rückweg zur Vorversion dokumentiert.
- Ersetzt: Aktivitätsanzeige in der Menüleiste, Vorssaint-Lüfter.

### Stufe 3: Speicher

- Liefert: NVMe-SMART mit Worst-Case-Note und Verlauf, Geschwindigkeitstest, Platzanalyse, Bereinigungskatalog, Duplikate, Deinstallation mit Besitzplan inklusive root-eigener Reste über den Helfer.
- Anforderungen: R30 bis R35, R37.
- Abnahme: Regeltabelle mit Versionstests; Einheiten- und Besitztests; Renntests (Symlinktausch, Umbenennung zwischen Plan und Bestätigung); Zwei-ähnliche-Apps-Test.
- Ersetzt: DriveDx, Disk Speed Test, Burrow, Uninstaller.

### Stufe 4: Audio und MIDI

- Liefert: Geräte, Standardgeräte, Format und Samplerate mit Readback, Aggregate und Multi-Output, MIDI-Geräte, Lautstärke und Stumm pro App.
- Anforderungen: R40 bis R44.
- Abnahme: Readback-Fehlertests mit Fake-HAL; Geräteverlust-Test; S4 auf echter Hardware wiederholt.
- Ersetzt: Audio-MIDI-Setup im Kern, Vorssaint-Mixer.

### Stufe 5: Bluetooth und Eingabe

- Liefert: Geräte mit Akkustand, BLE-Explorer mit ACK und Readback, Log-Export, Finder-⌘X, Trackpad-Haptik mit Materialklang.
- Anforderungen: R50 bis R53, R60, R61.
- Abnahme: CSV-Roundtrip; Frontmost-Gate-Test; Haptik-Fehlerstufen bei fehlenden Symbolen; kein MCP-Tool für Eingabe oder Haptik.
- Ersetzt: LightBlue im Kern, Command X, Feel My Mac.

### Stufe 6: Finder und Zwischenablage

- Liefert: Quick Look für Ordner und Archive, Finder-Kontextaktionen, Zwischenablageverlauf nur für den Menschen.
- Anforderungen: R70 bis R73.
- Abnahme: Zip-Bomb-Fixture; Paralleltest zweier Finder-Aufträge; Ausschluss-, Pause-, Lösch- und `serve`-Unerreichbarkeitstests für die Zwischenablage.
- Ersetzt: Folder Preview, MouseBoost Pro, Vorssaint-Zwischenablage.

### Später (eigene Planung)

- R17 Agent-Sessionwechsel in der Notch, sobald Brain Session-Status liefert (Codenotch-Rest).
- R18 Energie je Prozess, R36 Platzprognose, R38 Reste gelöschter Apps, R39 USB-SATA über smartctl, R45 Ausgabe pro App und Netzwerk-MIDI, R54 virtuelle BLE-Peripherie, R07 Kurzbefehle-Aktionen.
- Desktop: `symdesk pdf compress` (D03) mit eigener Planung und S7 im Desktop-Repo.

## 4. Validierung mit Nutzern

Daniel nutzt jede Stufe 30 Tage im Alltag. Erfolg (Z1): Die der Stufe zugeordneten Originale werden in dieser Zeit nicht mehr geöffnet. Agentenseitig: Hermes erledigt je Stufe drei typische Diagnoseaufgaben nur über MCP (zum Beispiel „Warum ist der Mac heiß?“, „Was belegt Platz?“, „Welches Audiogerät ist aktiv?“), ohne Shell-Umweg.

## 5. Release-Voraussetzungen

- Developer-ID-Signatur und Notarisierung für App, Helfer und künftig auch die CLI.
- Homebrew: Cask mit CLI-Link, Formula nur CLI, gegenseitig `conflicts_with` (D15); Release nur noch arm64.
- Helfer-Registrierung mit verständlicher Erklärung der Freigabe in den Anmeldeobjekten; `osascript`-Rückfall für lokale Builds.
- Upgrade von v0.12 ohne Datenverlust, Rückweg zur Vorversion, Release Notes.
- Build ist nicht Installation, ein Upload ist kein nutzbares Release: Abnahme jeweils am installierten Artefakt.

## 6. Übergabe

Nach G5: Vertragsrevision 9 nach dem Verfahren in `idea-to-architecture` (`references/symaira-fit.md`), danach `writing-plans` für Spikes S1 bis S6 und Stufe 0, danach `02-gh-plan` für Issues und Meilensteine. Parallel ein Planungsauftrag im Desktop-Repo für D03. ADRs liegen seit der Freigabe unter `docs/adr/0001` bis `0004`.

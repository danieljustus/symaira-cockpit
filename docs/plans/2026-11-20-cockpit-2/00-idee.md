# Idee: Symaira Cockpit (Rust-Neuaufbau)

> Status: freigegeben (2026-11-20, Daniel) · Aufgenommen: 2026-11-20 · Modus: standard

## Daniels Beschreibung (wörtlich)

> Lass uns eine neue bessere und umfassendere Version von Symaira Cockpit planen. Es soll wie die anderen Symaira Tools auf Rust Basis aufbauen (und wo unbedingt notwendig Swift oder anderes) und für AI ebenso wie für menschliche Nutzung optimiert sein (also CLI, MCP usw.).
>
> Es soll quasi Elemente und Funktionen von diesen Tools alle beinhalten und ersetzen (zu prüfen bleibt natürlich wie komplex das wirklich sein muss. also z.B. für pdf squeezer braucht man wirklich so eine hohe Ausqahl an kompressions engines usw.?). Möglichst alles bitte in Rust selber nachbauen.
>
> Apple Aktivitätsanzeige, Apple Audio-MIDI-Setup, Blackmagic Disk Speed Test, Burrow, Codenotch, Command X, Uninstaller, DriveDx, Feel My Mac, Folder Preview, LightBlue, MouseBoost Pro, PDF Squeezer, Vorssaint
>
> Optional zu prüfen ob es hier überhaupt gut reinpasst: Apple Automator, Cyberduck

(Pfadliste gekürzt auf die Anwendungsnamen; alle liegen unter `/Volumes/1TB_NVMe_SN850X/Dev/Reverse Engineering/<Name>`.)

## Einordnung

| Merkmal | Wert | Begründung |
|---|---|---|
| Spur | A: bestehendes Produkt Symaira Cockpit, mit Vertragsänderung | Cockpit besitzt laut [PB-2026-09-09](../../product-boundaries.md) Revision 8 nur „thermals, power, display, sensors and HUD“. Monitor-, Speicher-, Audio-, Bluetooth- und Finder-Funktionen sprengen diesen Rahmen. |
| Zweck | Eigenbedarf, öffentlich als Apache-2.0 | Cockpit ist öffentlich und hat ausdrücklich keine Pro-Edition (`tuning/docs/commercial-boundary.md`). |
| Größe | Produkt-Neuaufbau: Sprachwechsel Swift zu Rust plus mehrere neue Fachbereiche | 33.410 Zeilen Swift-Quellcode und 25.662 Testzeilen heute (`git ls-files '*.swift'`, 2026-11-20). |
| Modus | standard | Fünf Abstimmungen; Tief-Teardowns entfallen, weil alle 16 Originale bereits statisch analysiert sind. |
| Ablage | `symaira-cockpit/docs/plans/2026-11-20-cockpit-2/` | Spur A legt Planungsdokumente im besitzenden Repo ab (`idea-to-architecture`, `references/symaira-fit.md`). |

## Vorwissen

- **Produktvertrag:** Cockpit ist seit dem Cutover vom 2026-09-13 tune-only; Operate und Scope gehören Brain. Scope besitzt „ports, containers, daemons, local service health and machine diagnostics“ (PB §2, §4).
- **Frühere Entscheidung (Symaira Memory, 2026-08-24):** Cockpit bleibt eigenes Binary und eigenes Repo; Integration in Brain nur zur Laufzeit.
- **Adoptionsbericht Vorssaint (2026-11-10):** `docs/adopt/2026-11-10T10-50-35Z--vorssaint-vorssaint-utils.md` übernahm GPU-Messung aus der IORegistry, Lüfter-Failure-Policy und Helfer-Design als Muster und lehnte die übrige Breite (Mixer, Switcher, Clipboard) ausdrücklich als „outside Cockpit's product boundary“ ab. Diese Planung stellt genau diese Grenze zur Entscheidung.
- **OpenUsage-Parität (Sitzung 2026-10-28, PR #397):** Cockpit zeigt AI-Kontingente bereits über `symbrain usage`; Codenotch überschneidet sich damit.
- **Offene Issues:** #418 (App ~60 % CPU durch SwiftUI-Relayout), #414 (Lüfter nach Helfertod), #405 (SMAppService-Lüfterhelfer), #403 (Systemleistung getrennt von Netzteilleistung), #394 (OpenUsage-Parität), #375 (Notch-Animation).
- **Rust-Präzedenzfälle:** CoreKit (12 Rust-Crates inklusive MCP, Config, Update, SQLite), Brain (Rust-Kern plus Swift-Apps), Desktop (`symdesk-render` mit lopdf), Voice („Die Kommandozeile ist das Produkt“, App ohne Logik, Swift nur als Worker).
- Kein früherer Planungsordner für einen Cockpit-Neuaufbau gefunden (`_planning/`, `symaira-cockpit/docs/`).

## Annahmen

- A1: „Ersetzen“ meint die Funktionen, die Daniel tatsächlich nutzt, nicht vollständige Parität mit jedem Original. Prüfung in G2.
- A2: Vertrieb bleibt direkt (notarisiert, Homebrew Formula und Cask), nicht Mac App Store. Grund: SMC-Schreibzugriffe und globale CLI sind mit der Sandbox unvereinbar (`tuning/AGENTS.md`).
- A3: Nur macOS arm64 (Plattformbeschluss vom 2026-10-29); Intel-Pfade entfallen.
- A4: Die GUI bleibt SwiftUI nach den Symaira Interface Guidelines (CoreKit `swift/GUIDELINES.md`).
- A5: Bestehende Identifier bleiben: `com.symaira.symtune`, `com.symaira.symtune-helper`, `~/.config/symtune/`, `SYMTUNE_*`, Exit-Codes 0 bis 4, snake_case-JSON.
- A6: Agenten dürfen alles lesen, aber Schreib- und Löschaktionen nur über einen Plan mit ausdrücklicher Bestätigung.

## Offene Punkte für die Recherche

- Welche der 16 Originale passen in Cockpit, welche gehören einem anderen Produkt?
- Welche Plattformschnittstellen sind öffentlich, welche undokumentiert oder privat?
- Welche Rust-Bausteine existieren mit verträglicher Lizenz?
- Wie viel Funktionsumfang je Original braucht der Ersatz wirklich?

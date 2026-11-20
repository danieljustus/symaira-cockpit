# ADR 0004: `unsafe` nur in Plattform-Crates; undokumentierte und private Schnittstellen mit Fähigkeitserkennung

- Status: angenommen (2026-11-20, Daniel, Gate G4/G5 der Planung [Cockpit 2](../plans/2026-11-20-cockpit-2/README.md))
- Bezug: R10 bis R14, R20, R30, R44, R61, Q06; Risiko K3

## Kontext

Cockpit braucht FFI zu IOKit, SMC, IOReport, CoreAudio, CoreBluetooth, XPC und dem privaten MultitouchSupport. Voice verbietet `unsafe` ganz, hat aber keine Hardware-Domäne. Öffentlich sind NVMe-SMART (SDK-Header), Process Taps (macOS 14.2) und XPC-Peer-Signaturprüfung (macOS 12.0). Undokumentiert sind SMC, IOReport und die IOAccelerator-Schlüssel; privat ist MultitouchSupport.

## Entscheidung

- `unsafe` steht nur in `symcockpit-macos` und an der C-ABI-Grenze von `symcockpit-ffi`, jeweils hinter sicheren Wrappern mit dokumentierten Invarianten; alle anderen Crates setzen `#![forbid(unsafe_code)]`.
- Jede Funktion meldet ihre Stufe (`documented`, `undocumented`, `private`) und ist per Konfiguration abschaltbar.
- Private Symbole werden einzeln per `dlsym` geprüft; fehlende Symbole führen zu benannten Fehlerstufen, nie zum Absturz (RE/Feel My Mac).
- Kein Mac App Store; nur notarisierter Direktvertrieb.

## Konsequenzen

- Positiv: Prüfaufwand für Speichersicherheit bleibt auf eine Crate begrenzt.
- Negativ: Undokumentierte Pfade brauchen Pflege nach macOS-Updates.
- Folgearbeit: Fuzz-Tests für Parser (SMC-Werte, NVMe-Log, Archivköpfe); Abschalter in `doctor` sichtbar.

## Prüfung

Neu prüfen, wenn ein macOS-Update eine private Schnittstelle entfernt oder Apple eine öffentliche Alternative anbietet.

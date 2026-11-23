# Quellen: Symaira Cockpit (Rust-Neuaufbau)

Abruf aller Quellen: 2026-11-20. Typ: B Beobachtung, I Inferenz.

## Lokal

| Nr | Quelle | Typ | Inhalt |
|---|---|---|---|
| L1 | `/Volumes/1TB_NVMe_SN850X/Dev/Reverse Engineering/<Anwendung>/rebuild.md`, `report.md`, `features/` für alle 16 Originale | B | Clean-Room-Muster, Architektur, Befund-IDs |
| L2 | `/Volumes/1TB_NVMe_SN850X/Dev/Reverse Engineering/INDEX.md` | B | Analysestatus und übertragbare Muster |
| L3 | `Symaira_Dev/Repos/docs/product-boundaries.md` (PB-2026-09-09, Revision 8) | B | Produktbesitz |
| L4 | `symaira-cockpit/AGENTS.md`, `tuning/AGENTS.md`, `README.md`, `docs/command-map.md` | B | Heutiger Umfang, harte Regeln, Identifier |
| L5 | `git ls-files '*.swift'` in `symaira-cockpit` | B | 33.410 Quellzeilen, 25.662 Testzeilen, 355 Dateien |
| L6 | `gh issue list` in `symaira-cockpit` | B | #418, #414, #405, #403, #394, #375 |
| L7 | `symaira-cockpit/docs/adopt/2026-11-10T10-50-35Z--vorssaint-vorssaint-utils.md` | B | GPU aus IORegistry ohne root, Helfer-Design, Grenzentscheidung |
| L8 | `symaira-corekit/Cargo.toml` | B | 12 Rust-Crates, Edition 2024, Rust 1.98 |
| L9 | `symaira-desktop/crates/symdesk-render/Cargo.toml`, `src/pdfops.rs` | B | lopdf 0.47, Split/Merge/Rotate |
| L10 | `symaira-brain/scope/README.md`, `symaira-brain/rust/` | B | Scope-Umfang, `symbrain-usage` |
| L11 | `symaira-voice/AGENTS.md` | B | CLI als Produkt, App ohne Logik |
| L12 | Xcode-SDK `IOKit/storage/nvme/NVMeSMARTLibExternal.h` | B | Öffentliche NVMe-SMART-Schnittstelle |
| L13 | Xcode-SDK `CoreAudio/AudioHardwareTapping.h` | B | Process Taps ab macOS 14.2 |
| L14 | Xcode-SDK `usr/include/xpc/connection.h` | B | Peer-Signaturprüfung ab macOS 12.0 |
| L15 | Xcode-SDK `usr/lib/libIOReport.tbd` | B | IOReport linkbar, kein öffentlicher Header |
| L16 | Symaira Memory und Sitzung 2026-10-28 (OpenUsage, PR #397) | B | Vorentscheidungen |

## Extern

| Nr | Quelle | Typ |
|---|---|---|
| E1 | GitHub-API `gh api repos/<owner>/<repo>` für alle Repos in `candidates.json` (Lizenz, Sterne, letzter Push, Beschreibung) | B |
| E2 | crates.io-API `https://crates.io/api/v1/crates/<name>` für alle Crates in `candidates.json` (Version, Lizenz, Aktualisierung) | B |
| E3 | macmon, Repo-Beschreibung „Real-time system monitor for Apple Silicon Macs. No sudo.“ https://github.com/vladkens/macmon | B |
| E5 | actuallymentor/battery PR #480 „Support macOS 27: use the macOS charge limit when the SMC charge keys are gone“ https://github.com/actuallymentor/battery/pull/480 | B |
| E6 | az-code-lab/ampere, README Abschnitt „Firmware without CHTE“ https://github.com/az-code-lab/ampere | B |
| E7 | „How macOS 27 broke charge limiters“ https://jiraffekiller.github.io/sail/ | B |
| E4 | Burrow, Repo-Beschreibung „Cleanup, app management, maintenance, disk analysis, and live status … support for AI agents“ https://github.com/caezium/burrow | B |

# 2D-3 Teil 2: Swift-Kern entfernen — Inventar

Stand 2026-11-22, Branch `c2/2d3-swift-removal` (Basis 2101a7c). Zeilenzahlen sind die Zeilen der entfernten Dateien in der Basis.

## Methode

1. Wurzeln (bleiben): `Sources/SymCockpitApp`, `Sources/SymCockpitFanHelper`, `Sources/SymCockpitVersion`, `tuning/Sources/SymCockpitUI`, `SymCockpitMenuBarApp`, `SymCockpitHelperKit`.
2. Symbolsuche: je SymCockpitCore-Datei die Namen ihrer Typen auf oberster Ebene (Kommentare und Zeichenketten ausgenommen). Eine Datei lebt, wenn eine Wurzel oder eine lebende Core-Datei einen ihrer Namen nennt (Fixpunkt; überschätzt eher, als dass er zu viel löscht). Ergebnis: 61 lebende, 35 tote Dateien (inkl. `TuneController` und seiner Erweiterungen).
3. Build-Beweis: nach jedem Schritt `swift build` und `swift test` (Root), `swift test --package-path tuning`, am Ende `history`. Tests, die Entferntes nennen, wurden entfernt oder auf die Methoden gekürzt, die lebenden Code prüfen.

## Entschieden: entfernt

| Bereich | Dateien | Zeilen | Grund |
| :-- | --: | --: | :-- |
| `Sources/symcockpit` | 4 | 304 | Swift-Dispatcher; ausgeliefert wird das Rust-Binary, kein Befehl startet Swift (`crates/symcockpit/tests/no_swift.rs`) |
| `tuning/Sources/SymCockpitCLI` | 3 | 902 | Befehlsbibliothek des Dispatchers; keine Wurzel nutzt sie |
| `tuning/Sources/SymCockpitMCP` | 3 | 601 | MCP-Server in Swift; der MCP-Server ist Rust |
| `tuning/Sources/symtune` | 1 | 8 | Paketlokaler Einstieg, nur Aufruf von SymCockpitCLI |
| `tuning/Sources/SymCockpitCore` | 35 | 5067 | `TuneController` und nur von ihm, CLI und MCP erreichte Dienste (Liste unten) |
| `tuning/Tests/SymCockpitCLITests` | 3 | 87 | Tests der entfernten CLI-Bibliothek |
| `tuning/Tests/SymCockpitMCPTests` | 5 | 1087 | Tests des entfernten MCP-Servers |
| `tuning/Tests/SymCockpitCoreTests` | 31 | 4936 | Tests der entfernten Core-Dateien (ganze Dateien) plus Fakes ohne Verbraucher; gemischte Dateien siehe unten |
| `Tests/SymCockpitE2ETests` | 12 | 1547 | 12 Suiten, die das Swift-Binary `symcockpit` als Kindprozess starten; das Binary existiert nicht mehr |
| **Summe (gelöschte Dateien)** | **97** | **14539** | |

Dazu kommen Kürzungen in 11 gemischten Testdateien (unten) und die Änderungen an Manifest, CI, Makefile und Doku. Gesamtdiff der drei Commits: siehe `git diff --shortstat 2101a7c HEAD`.

### Entfernte Core-Dateien (je Datei)

| Datei | Zeilen | Grund |
| :-- | --: | :-- |
| `AwakeOptions.swift` | 102 | CLI-Argumente `awake` |
| `ChargeLimitService.swift` | 174 | Schreibpfad nur über TuneController |
| `ChargeLimitState.swift` | 32 | Zustand von ChargeLimitService |
| `DimOverlay.swift` | 86 | Dimm-Overlay des Controllers |
| `DisplayEnumerationSource.swift` | 53 | Quelle für DisplayService |
| `DisplayGamma.swift` | 139 | Gamma für Wärme/EDR im Controller |
| `DisplayGammaController.swift` | 183 | Gamma für Wärme/EDR im Controller |
| `DisplayHelpers.swift` | 49 | Hilfen für DisplayService |
| `DisplayService.swift` | 212 | Display-Schreibpfad des Controllers |
| `DisplayWriteService.swift` | 80 | Display-Schreibpfad des Controllers |
| `DurationParser.swift` | 49 | nur von den CLI-Optionen genutzt |
| `EDROverlayService.swift` | 500 | EDR-Overlay des Controllers |
| `HealthScorer.swift` | 108 | nur `status` im CLI |
| `HistoryOptions.swift` | 45 | CLI-Argumente `history` |
| `HistoryService.swift` | 53 | History-Schreiber des Controllers (Rust schreibt den Verlauf) |
| `IORegistryGPUProcessSource.swift` | 152 | GPU-Prozessquelle, nur von ProcessUsageService |
| `KeepAwakeCoordinator.swift` | 128 | Wachhalten im Controller (Rust) |
| `OverrideTracker.swift` | 137 | Override-Buchführung des Controllers |
| `PowerAssertionSource.swift` | 45 | Quelle für PowerService |
| `PowerService.swift` | 31 | Wachhalten im Controller |
| `PowerWakeMonitor.swift` | 101 | Wake-Monitor des CLI-`serve` |
| `PowermetricsGPUProcessSource.swift` | 156 | GPU-Prozessquelle, nur von ProcessUsageService |
| `ProcessListingPresentation.swift` | 158 | CLI-Tabelle `processes` |
| `ProcessUsageService.swift` | 176 | Dienst nur für TuneController/CLI |
| `RedactedErrorLine.swift` | 41 | stderr-Zeile des CLI |
| `SMCHelperProtocol.swift` | 86 | alter Helfer-Vertrag, ersetzt durch `SymCockpitHelperKit` |
| `SMCRestoreRecord.swift` | 53 | nur SMCRestoreTracker |
| `SMCRestoreTracker.swift` | 248 | Restore-Buchführung des Controllers (Rust: ein `restore`) |
| `StatusOptions.swift` | 52 | CLI-Argumente `status` |
| `SystemMetricsService.swift` | 84 | Dienst nur für TuneController/CLI |
| `TuneController+AIUsageAPI.swift` | 14 | Erweiterung von TuneController |
| `TuneController.swift` | 1247 | Fassade des alten CLI/MCP; App und UI nutzen nur `AgentSession`/`AgentClient` |
| `TuneControllerErrorMapping.swift` | 31 | Fehlerabbildung von TuneController |
| `UntilTimeParser.swift` | 43 | nur von AwakeOptions genutzt |
| `WriteCommand.swift` | 219 | Befehlstabelle des Controllers |

### Entfernte Testdateien in `SymCockpitCoreTests`

`CLIOptionParsingTests.swift`, `ChargeLimitServiceTests.swift`, `ControllerControlRegressionTests.swift`, `DimAmountMappingTests.swift`, `DisplayGammaTests.swift`, `DisplayServiceTests.swift`, `EDROverlayServiceTests.swift`, `ErrorRedactionTests.swift`, `FakeDisplayEnumerationSource.swift`, `FakePowerAssertionSource.swift`, `FakeProcessSampleSource.swift`, `FakeSystemMetricsSource.swift`, `HistoryTests.swift`, `KeepAwakeCoordinatorTests.swift`, `OverrideTrackerTests.swift`, `PowerServiceTests.swift`, `PowermetricsGPUProcessSourceTests.swift`, `ProcessListingPresentationTests.swift`, `ProcessNameDecodingTests.swift`, `SMCRestoreFileTests.swift`, `SMCRestoreTrackerTests.swift`, `StatusTests.swift`, `SystemMetricsServiceTests.swift`, `TuneControllerCoolTargetTests.swift`, `TuneControllerFanChargeTests.swift`, `TuneControllerFanHelperTests.swift`, `TuneControllerFanPrivilegeTests.swift`, `TuneControllerProcessBrightnessTests.swift`, `TuneControllerSensorsKeepAwakeTests.swift`, `TuneControllerWritePathErrorTests.swift`, `WriteCommandChargeLimitTests.swift`.

Gründe: Subjekt entfernt (TuneController*, ChargeLimit, EDR, KeepAwake, Gamma, Override, Power, SMCRestore, Display, ProcessListing, SystemMetrics, WriteCommand, CLIOptionParsing, Status), oder der Test prüfte nur den entfernten stderr-Pfad (`ErrorRedactionTests`; `SecretRedactor` selbst bleibt im Paket `history` getestet), oder er baute nur auf `HistoryService` (`HistoryTests`). Die Fakes `FakeDisplayEnumerationSource`, `FakePowerAssertionSource`, `FakeProcessSampleSource`, `FakeSystemMetricsSource` haben keinen Verbraucher mehr.

## Entschieden: behalten (mit Kürzung)

| Testdatei | Wirkung | Grund |
| :-- | :-- | :-- |
| `ElevatedStateOwnershipTests` | 1 Test (Controller/HistoryService) entfernt | `StateFilePermissions` lebt (FanProfile, Fan-Helfer) |
| `HardwareBackendIntegrationTests` | 2 Tests entfernt | `HardwareBatterySource` und SMC-Verbindung leben |
| `BatteryHealthParserTests` | 2 Tests entfernt | `BatteryHealthParser` lebt; entfernt: JSON-Durchreichung über SystemMetricsService |
| `ConfigTests` | 3 Tests entfernt | `TuneConfig` lebt (Fan-Helfer) |
| `GPURegistryTests` | Klasse `IORegistryGPUProcessSourceTests`, Fallback-Fakes und 3 Tests entfernt | `IORegistryGPUReader`-Parser und `GPUReport` leben |
| `PrivilegedElevationVersionTests` | 1 Test (Controller) entfernt | `PrivilegedElevation` lebt (App) |
| `ProcessUsageTests` | Klasse `ProcessUsageServiceTests`, GPU-Stub entfernt | `ProcessUsage`/`ProcessSortKey` leben (TopProcessesCard) |
| `StorageVolumeServiceTests` | 1 Test (SystemMetricsService) entfernt | `StorageVolumeService` lebt (StorageVolumesCard) |
| `SymTuneCoreTests` | Klassen `WriteSurfaceTests`, `TuneControllerWritePathTests`, `TuneControllerProfileTests`, `CapabilityTests` entfernt | SafetyPolicy, SMCKey, SemVer, UpdateChecker leben |
| `SystemPowerTests` | 4 Capability-Tests (Controller) entfernt | Leistungsparser leben |

## Entschieden: behalten (SymCockpitCore, 61 Dateien)

Jede Datei mit der Stelle, über die sie erreicht wird (Wurzel oder lebende Datei, Name).

| Datei | erreicht von | über |
| :-- | :-- | :-- |
| `AIUsage.swift` | `tuning/Sources/SymCockpitUI/PreferencesView.swift` | `AIUsageProvider` |
| `AIUsageEnabledProviders.swift` | `tuning/Sources/SymCockpitUI/AIUsagePreferences.swift` | `AIUsageEnabledProviders` |
| `AIUsageFormatting.swift` | `tuning/Sources/SymCockpitUI/AIUsageViewModel.swift` | `AIUsageFormatting` |
| `AIUsageLocalAPI.swift` | `AIUsageLocalServer.swift` | `AIUsageLocalAPI` |
| `AIUsageLocalRecordedSpend.swift` | `tuning/Sources/SymCockpitUI/AIUsageLocalRecordedSpendView.swift` | `AIUsageLocalRecordedSpend` |
| `AIUsageLocalServer.swift` | `tuning/Sources/SymCockpitUI/AIUsageAPIHost.swift` | `AIUsageLocalServer` |
| `AIUsageLocalSnapshots.swift` | `tuning/Sources/SymCockpitUI/AIUsageAPIHost.swift` | `AIUsageLocalSnapshots` |
| `AIUsagePresentation.swift` | `tuning/Sources/SymCockpitUI/AIUsageShareCard.swift` | `AIUsageLayout` |
| `AIUsageProviderLink.swift` | `tuning/Sources/SymCockpitUI/AIUsageCardView.swift` | `AIUsageProviderLink` |
| `AIUsageRecordedHistory.swift` | `tuning/Sources/SymCockpitUI/AIUsageViewModel.swift` | `AIUsageRecordedHistory` |
| `AIUsageService.swift` | `tuning/Sources/SymCockpitUI/AIUsageViewModel.swift` | `AIUsageService` |
| `AIUsageSnapshotCache.swift` | `AIUsageService.swift` | `AIUsageSnapshotCache` |
| `AgentClient.swift` | `tuning/Sources/SymCockpitUI/BrightnessKeyController.swift` | `AgentJSON` |
| `AgentModels.swift` | `tuning/Sources/SymCockpitUI/AgentDiagnosisCard.swift` | `AgentDiagnosis` |
| `AgentSession.swift` | `Sources/SymCockpitApp/AppDelegate.swift` | `AgentSession` |
| `BatteryHealthParser.swift` | `BatteryService.swift` | `AppleBatteryHealthProviding` |
| `BatteryService.swift` | `SMCWritePolicy.swift` | `BatteryService` |
| `BatterySource.swift` | `SystemMetricsSource.swift` | `HardwareBatterySource` |
| `BeyondNormalBrightness.swift` | `tuning/Sources/SymCockpitUI/ControlCards.swift` | `BeyondNormalBrightness` |
| `BrightnessKeys.swift` | `tuning/Sources/SymCockpitUI/BrightnessKeyController.swift` | `BrightnessKeyStep` |
| `Config.swift` | `Sources/SymCockpitFanHelper/main.swift` | `TuneConfig` |
| `Errors.swift` | `tuning/Sources/SymCockpitHelperKit/FanHelperClient.swift` | `TuneError` |
| `ExitCode.swift` | `Errors.swift` | `ExitCode` |
| `FanControlService.swift` | `Sources/SymCockpitFanHelper/main.swift` | `FanControlService` |
| `FanCoolTarget.swift` | `tuning/Sources/SymCockpitUI/FanCoolTargetRow.swift` | `FanCoolTarget` |
| `FanGovernor.swift` | `Sources/SymCockpitFanHelper/main.swift` | `FanGovernor` |
| `FanGovernorProcessProbe.swift` | `Sources/SymCockpitFanHelper/main.swift` | `FanGovernorProcessProbe` |
| `FanHelperRouting.swift` | `tuning/Sources/SymCockpitUI/FanHelperPreferences.swift` | `FanHelperDefaults` |
| `FanProfile.swift` | `tuning/Sources/SymCockpitUI/TuneViewModel+Actions.swift` | `FanProfile` |
| `GPURegistry.swift` | `Models.swift` | `GPUReport` |
| `HUDDockLayout.swift` | `tuning/Sources/SymCockpitUI/HUDDemoController.swift` | `HUDDock` |
| `HUDDragPhysics.swift` | `tuning/Sources/SymCockpitUI/HUDDockView.swift` | `HUDDragState` |
| `HUDItemLayout.swift` | `tuning/Sources/SymCockpitUI/HUDDemoController.swift` | `HUDItemKind` |
| `HUDPresentation.swift` | `tuning/Sources/SymCockpitUI/HUDDockView.swift` | `HUDPresentation` |
| `KeychainCredentials.swift` | `SymVaultCredentialStore.swift` | `KeychainCredentials` |
| `MetricFormatting.swift` | `tuning/Sources/SymCockpitUI/TopProcessesCard.swift` | `MetricFormatting` |
| `MetricRowData.swift` | `tuning/Sources/SymCockpitUI/MetricsHistoryCard.swift` | `MetricRowData` |
| `MetricStyle.swift` | `tuning/Sources/SymCockpitUI/HUDItemRendering.swift` | `CalendarWeekFormatting` |
| `MetricsHistoryService.swift` | `tuning/Sources/SymCockpitUI/TuneViewModel.swift` | `MetricsHistoryService` |
| `MetricsRingBuffer.swift` | `tuning/Sources/SymCockpitUI/SparklineView.swift` | `MetricSample` |
| `Models.swift` | `tuning/Sources/SymCockpitUI/BrightnessKeyController.swift` | `BrightnessReadback` |
| `NetworkService.swift` | `UpdateChecker.swift` | `NetworkServiceProtocol` |
| `NotchLayout.swift` | `tuning/Sources/SymCockpitUI/HUDDockView.swift` | `NotchLayout` |
| `PrivilegedElevation.swift` | `Sources/SymCockpitApp/AppDelegate.swift` | `PrivilegedElevation` |
| `ProcessUsage.swift` | `tuning/Sources/SymCockpitUI/TopProcessesCard.swift` | `ProcessUsage` |
| `ProfileService.swift` | `Models.swift` | `TuneProfile` |
| `ReadoutSurface.swift` | `tuning/Sources/SymCockpitUI/StatusBarController.swift` | `ReadoutSurfaceDefaults` |
| `SMCService.swift` | `Sources/SymCockpitFanHelper/main.swift` | `SMCService` |
| `SMCWritePolicy.swift` | `FanControlService.swift` | `SMCWritePolicy` |
| `SafetyPolicy.swift` | `Config.swift` | `SafetyPolicy` |
| `SecretRedactor.swift` | `tuning/Sources/SymCockpitUI/TuneViewModel+Actions.swift` | `SecretRedactor` |
| `SensorService.swift` | `Sources/SymCockpitFanHelper/main.swift` | `SensorService` |
| `StateFilePermissions.swift` | `FanProfile.swift` | `StateFilePermissions` |
| `StorageVolumeService.swift` | `tuning/Sources/SymCockpitUI/StorageVolumesCard.swift` | `StorageVolumeReport` |
| `SymBrainUsageClient.swift` | `AIUsageService.swift` | `SymBrainUsageError` |
| `SymBrainUsageProvider.swift` | `tuning/Sources/SymCockpitUI/AIUsageViewModel.swift` | `SymBrainUsageProvider` |
| `SymVaultCredentialStore.swift` | `tuning/Sources/SymCockpitUI/AIUsagePreferencesSection.swift` | `SymVaultCredentialStore` |
| `SystemMetricsSource.swift` | `StorageVolumeService.swift` | `DiskStatistics` |
| `TOMLParser.swift` | `Config.swift` | `TOMLTable` |
| `UpdateChecker.swift` | `tuning/Sources/SymCockpitUI/StatusBarController.swift` | `UpdateChecker` |
| `Version.swift` | `tuning/Sources/SymCockpitUI/StatusBarController.swift` | `TuneVersion` |

Symbolgrenze: die Entscheidung gilt je Datei. Einzelne Typen in lebenden Dateien haben jetzt keinen Verbraucher mehr (z. B. `ProcessSample`/`ProcessSampleSource` in `ProcessUsage.swift`, `FanHelperControlling` in `FanHelperRouting.swift`, Berichts-Typen in `Models.swift`). Sie wurden nicht angefasst, weil ein Typ-für-Typ-Schnitt in denselben Dateien mit der Oberflächenwelle (`c2/2d3-shell`) kollidieren würde. Folgeaufgabe.

## Entschieden: behalten (übrige Ziele)

| Ziel | Grund |
| :-- | :-- |
| `Sources/SymCockpitApp`, `SymCockpitFanHelper`, `SymCockpitVersion` | App, Fan-Helfer (Swift, SMAppService/XPC), gemeinsame Version |
| `tuning/Sources/SymCockpitUI`, `SymCockpitMenuBarApp`, `SymCockpitHelperKit` | GUI und Helfer-Vertrag |
| `history/` (ganzes Paket) | `SymCockpitCore` hängt davon ab: `BoundedProcessRunner` (PrivilegedElevation, SymVault, SymBrain-Client, FanGovernorProcessProbe) und `SecretRedactor` (Ausgabegrenze von AIUsage und UI; AGENTS.md nennt es die Datenschutzgrenze). `CanonicalHistory` und `ReplayCodec` haben keinen Produktionsverbraucher mehr; der Rust-Store (`crates/symcockpit-store/src/history.rs`) verweist in Kommentaren auf `CanonicalHistory.swift` als Referenz. Ein Kürzen ist eine eigene Entscheidung. |
| `Tests/SymCockpitE2ETests` (übrige 28 Suiten) | GUI-, HUD-, AI-Usage-, Agent-Modell-Tests; keine startet ein Binary |
| `oracle/`, `crates/symcockpit-oracle` | unverändert (Vorgabe) |

## Beweis

Logs: `~/.hermes/cache/scratch/2d3/` (`00-baseline-*`, `a*`, `b*`, `c*`). Zählung aus den `.xctest`-Bündelsummen.

| Stand | Root `swift test` | `tuning` `swift test` | `history` `swift test` |
| :-- | :-- | :-- | :-- |
| Basis 2101a7c | 132 Tests, 4 übersprungen, Exit 0 | 1322 (Core 1154, HelperKit 98, MCP 62, CLI 8), Exit 0 | nicht gemessen (Quellen unverändert) |
| (a) Root-Dispatcher | 82, 4 übersprungen, Exit 0 | – | – |
| (b) CLI/MCP/symtune | 82, 4 übersprungen, Exit 0 | 1252 (Core 1154, HelperKit 98), Exit 0 | – |
| (c) TuneController und Dienste | 82, 4 übersprungen, Exit 0 | 917 (Core 819, HelperKit 98), Exit 0 | 41, Exit 0 |

## Issue #424

Auf der Basis änderte `swift test --package-path tuning` die Datei `~/.local/share/symtune/history.ndjson` (mtime 1795356600 → 1795357047 im Basislauf), weil Tests `TuneController` ohne `dataDir` bauten. Mit (c) sind diese Tests entfernt; der komplette Swift-Testlauf nach (c) (tuning, Root, history) ließ mtime (1795357440) und alle Dateien unter `~/.local/share/symtune` und `~/.symtune` unverändert.

## Nachgezogen

- `Package.swift` (Root): Produkt und Target `symcockpit` entfernt. `tuning/Package.swift`: Produkte `SymCockpitMCP`, `SymCockpitCLI`, `symtune`, Targets und Testziele entfernt. `tuning/project.yml` (XcodeGen) enthielt weder CLI noch MCP; keine Änderung nötig. `Package.resolved` unverändert (corekit bleibt).
- `.github/workflows/ci.yml`: Kommentare der Jobs `root` und der Release-Diagnose-Regex (`ProcessUsageService` entfernt); Jobs und Schritte bleiben, weil `tuning`, `history` und `root` weiter Swift bauen und testen. `scripts/ci-changed-areas.sh` braucht keine Änderung (Pfadtabelle kennt keine entfernten Ziele); `scripts/test-ci-changed-areas.sh` grün.
- `tuning/Makefile` (Ziele `run`, `doctor`, `serve`), `tuning/scripts/coverage.sh` (Scope-Hinweis), `README.md`, `CONTRIBUTING.md`, `tuning/README.md`, `tuning/CONTRIBUTING.md`, `tuning/docs/{architecture,hardware-matrix,manual-app-verification}.md`: Verweise auf `swift run symtune` und die Swift-CLI auf das Rust-Binary umgestellt. `tuning/SAFETY_AUDIT.md` und `docs/tune-naming-inventory.md` tragen einen Hinweis, dass die zitierten Swift-Pfade entfernt sind (Auditstand, keine Neufassung).
- Rust: zwei Drift-Wächter lasen entfernte Swift-Quellen und brachen `cargo test`: `registry.rs::mcp_names_match_the_swift_sources` (Kommentar: „delete with it when the Swift sources are retired“) gelöscht; `sensors.rs::missing_charge_limit_key_text_is_the_swift_text` liest nicht mehr `TuneController.swift`, prüft aber weiter den Text. Kommentare „Vectors: tuning/Tests/…“ in `crates/` verweisen auf entfernte Testdateien (Herkunft, nur in der Git-Historie).

## Nicht angefasst (gehört dem Release-Worker)

- `.github/workflows/release.yml` Zeilen 67 und 78: `swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/symcockpit` baut das entfernte Swift-Produkt `symcockpit`; der CLI-Job muss auf das Rust-Binary umgestellt werden. Der Test `GUIVersionConsistencyTests` verlangt weiter, dass release.yml `Sources/SymCockpitVersion/CockpitVersion.swift` liest.
- `scripts/build-app.sh`, `smoke-app.sh`, `build-extensions.sh` nennen keine entfernten Ziele (bauen das Rust-Binary); `build-app.sh` und `smoke-app.sh` liefen grün.

## Schlusslauf (Stand nach allen Änderungen)

Root `swift build` Exit 0; Root `swift test` 82 Tests, 4 übersprungen, Exit 0; `tuning` 917 Tests (Core 819, HelperKit 98), Exit 0; `history` 41, Exit 0; `scripts/build-app.sh` (ad hoc) Exit 0; `scripts/smoke-app.sh` Exit 0; `cargo fmt --check` Exit 0; `cargo clippy --all-targets --locked -- -D warnings` Exit 0; `cargo test --workspace --locked` Exit 0 (51 Ergebnisblöcke, 961 bestanden, 0 fehlgeschlagen, 21 ignoriert). mtime von `~/.local/share/symtune/history.ndjson` im Schlusslauf unverändert (1795358406 vor und nach dem Swift-Testlauf).

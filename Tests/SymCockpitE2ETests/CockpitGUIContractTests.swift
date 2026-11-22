import XCTest

/// Product-boundary guard; live window checks cover sizing and interaction.
final class CockpitGUIContractTests: XCTestCase {
    func testWindowOpensTheSharedWorkspaceWithoutModuleNavigation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSources = root.appendingPathComponent("Sources/SymCockpitApp")
        let files = try FileManager.default.contentsOfDirectory(
            at: appSources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let window = try String(
            contentsOf: appSources.appendingPathComponent("CockpitRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(window.contains("statusBar.cockpitWorkspace("),
                      "the window must open the workspace the status bar controller builds from the shared models")
        for retired in ["OverviewView", "CockpitSection", "TuneSectionView",
                        "com.symaira.cockpit.section", "refreshCurrentSection",
                        "cockpitFocusSectionFilter", "Tune Preferences"] {
            XCTAssertFalse(source.contains(retired), "retired module shell remains: \(retired)")
        }
        XCTAssertFalse(window.contains(".toolbar"), "The shared workspace owns the single settings entry")
        XCTAssertTrue(window.contains("openPreferences: openPreferences"))
    }

    /// Source guard supplements live AX checks; it does not replace them.
    func testSharedTuningControlsKeepExplicitAccessibleNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = root.appendingPathComponent("tuning/Sources/SymCockpitUI")
        for file in ["TuneSliderRow.swift", "CenterAnchoredSliderRow.swift"] {
            let source = try String(contentsOf: ui.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(".accessibilityLabel(title)"), file)
            XCTAssertTrue(source.contains(".accessibilityValue(format("), file)
        }
        let keepAwake = try String(
            contentsOf: ui.appendingPathComponent("KeepAwakeCard.swift"), encoding: .utf8
        )
        XCTAssertTrue(keepAwake.contains("Toggle(\"Keep display awake\""))
        XCTAssertTrue(keepAwake.contains(".accessibilityLabel(\"Keep display awake\")"))
        XCTAssertTrue(keepAwake.contains("Text(\"Duration\")"))
        let status = try String(
            contentsOf: ui.appendingPathComponent("StatusCards.swift"), encoding: .utf8
        )
        XCTAssertTrue(status.contains(".accessibilityLabel(label)"))
        XCTAssertTrue(status.contains("Loading battery…"))
        XCTAssertTrue(status.contains("sensors?.thermalPressure ?? \"Loading…\""))
        XCTAssertFalse(status.contains("sensors?.thermalPressure ?? \"nominal\""))
        let panel = try String(
            contentsOf: ui.appendingPathComponent("MainStatusView.swift"), encoding: .utf8
        )
        // Liquid Topography: the panel follows the system appearance with adaptive
        // roles; forcing dark would hide the approved light palette.
        XCTAssertFalse(panel.contains(".preferredColorScheme(.dark)"))
        XCTAssertTrue(panel.contains("SymairaTokens.canvas"))
        XCTAssertFalse(panel.contains("SymairaTheme.goldPrimary"),
                       "selection must use the adaptive selected role, not fixed gold")
    }

    /// The window is a shell with one agent-backed page per destination.
    func testWorkspaceHasEveryDestinationAndNoControllerDependency() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = root.appendingPathComponent("tuning/Sources/SymCockpitUI")
        func source(_ name: String) throws -> String {
            try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
        }
        let shell = try source("CockpitWorkspaceView.swift")
        let window = try String(
            contentsOf: root.appendingPathComponent("Sources/SymCockpitApp/CockpitRootView.swift"), encoding: .utf8
        )
        XCTAssertEqual(window.components(separatedBy: "statusBar.cockpitWorkspace(").count - 1, 1)
        XCTAssertTrue(shell.contains("SymairaWorkspace("))
        XCTAssertTrue(shell.contains("SymairaNavigationButton("))
        XCTAssertTrue(shell.contains("SymairaSidebarToggle(sidebar: $sidebarLayout)"))
        XCTAssertTrue(shell.contains("SymairaSettingsMenu(selection: $appearance.selection, openSettings: openPreferences)"))
        XCTAssertFalse(shell.contains("Text(\"Preferences\")"), "Do not duplicate settings in the sidebar")
        XCTAssertFalse(shell.contains("clipShape(contentPanel)"), "panel rules belong in AppKit")
        XCTAssertTrue(shell.contains("topography: navigation.selection == .overview ? topography : nil"),
                      "the topography belongs to the overview only")
        XCTAssertTrue(shell.contains("AgentDiagnosisCard("), "the diagnosis replaces the page while the agent is down")
        for name in ["Storage", "AudioMIDI", "BluetoothInput", "Processes", "Clipboard", "Finder"] {
            let page = try source("\(name)Page.swift")
            XCTAssertTrue(page.contains("struct \(name)Page: View"), name)
            XCTAssertTrue(page.contains("SymairaPage("), name)
            XCTAssertFalse(page.contains("\"Not available yet\""), name)
            XCTAssertFalse(page.contains("TuneController"), name)
            XCTAssertFalse(page.contains("Process("), name)
        }
        // The window gains no new dependency on the hardware controller.
        for name in ["CockpitWorkspaceView.swift", "CockpitPages.swift", "CockpitDestination.swift", "OverviewPage.swift",
                     "DisplayPage.swift", "PowerFansPage.swift", "AIUsagePage.swift", "HistoryPage.swift",
                     "PlanConfirmationView.swift", "ChargeLimitCard.swift", "ProfilesCard.swift"] {
            let page = try source(name)
            XCTAssertFalse(page.contains("TuneController"), name)
            XCTAssertFalse(page.contains("Process("), name)
        }
        XCTAssertFalse(shell.contains(".task"))
        let cards = try source("StatusCards.swift")
        XCTAssertTrue(cards.contains(".cockpitProtected(hill: true)"))
        XCTAssertTrue(cards.contains("colorSchemeContrast"))
    }
}

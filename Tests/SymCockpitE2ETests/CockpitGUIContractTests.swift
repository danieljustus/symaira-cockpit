import XCTest

/// Product-boundary guard; live window checks cover sizing and interaction.
final class CockpitGUIContractTests: XCTestCase {
    func testWindowOpensSharedTuningPanelWithoutModuleNavigation() throws {
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

        XCTAssertTrue(window.contains("statusBar.tunePanel(chrome: .embedded)"),
                      "the window must open the existing tuning panel directly")
        for retired in ["OverviewView", "CockpitSection", "TuneSectionView",
                        "com.symaira.cockpit.section", "refreshCurrentSection",
                        "cockpitFocusSectionFilter", "Tune Preferences"] {
            XCTAssertFalse(source.contains(retired), "retired module shell remains: \(retired)")
        }
        XCTAssertTrue(window.contains("Label(\"Preferences\", systemImage: \"gearshape\")"))
    }

    /// Source guard supplements live AX checks; it does not replace them.
    func testSharedTuningControlsKeepExplicitAccessibleNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = root.appendingPathComponent("tune/Sources/SymTuneUI")
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
        XCTAssertTrue(panel.contains(".preferredColorScheme(.dark)"),
                      "adaptive text must use dark appearance on the fixed dark canvas")
    }

    /// One mounted panel is essential: navigating must not discard draft controls.
    func testWorkspaceNavigationKeepsSharedPanelAndEveryDestination() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = root.appendingPathComponent("tune/Sources/SymTuneUI")
        let shell = try String(contentsOf: ui.appendingPathComponent("CockpitWorkspaceView.swift"), encoding: .utf8)
        let panel = try String(contentsOf: ui.appendingPathComponent("MainStatusView.swift"), encoding: .utf8)
        let window = try String(
            contentsOf: root.appendingPathComponent("Sources/SymCockpitApp/CockpitRootView.swift"), encoding: .utf8
        )
        XCTAssertTrue(window.contains("CockpitWorkspaceView("))
        XCTAssertEqual(window.components(separatedBy: "statusBar.tunePanel(").count - 1, 1)
        XCTAssertTrue(shell.contains("ScrollViewReader"))
        XCTAssertTrue(shell.contains("scroll.scrollTo(anchor, anchor: .top)"))
        XCTAssertTrue(shell.contains("accessibilityReduceMotion"))
        XCTAssertTrue(shell.contains("geometry.size.width >= 840"))
        XCTAssertTrue(shell.contains(".accessibilityLabel(\"Jump to "))
        for anchor in ["overview", "display", "power", "activity", "readout"] {
            XCTAssertEqual(panel.components(separatedBy: ".id(TuneWorkspaceAnchor.\(anchor))").count - 1, 1)
        }
        for component in ["DisplayControlsCard(", "KeepAwakeSection(", "FanControlCard(",
                          "MenuBarVisibilityCard(", "TopProcessesCard("] {
            XCTAssertEqual(panel.components(separatedBy: component).count - 1, 1, component)
        }
        XCTAssertFalse(shell.contains("TuneController"))
        XCTAssertFalse(shell.contains("Process("))
        XCTAssertFalse(shell.contains(".task"))
    }
}

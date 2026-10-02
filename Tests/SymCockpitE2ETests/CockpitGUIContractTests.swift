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
}

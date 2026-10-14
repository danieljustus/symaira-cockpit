import XCTest

/// Source wiring guards, not native click or accessibility acceptance.
final class CockpitControlWiringTests: XCTestCase {
    private var ui: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tuning/Sources/SymCockpitUI")
    }

    func testDisplayAndPowerActionsDoNotDiscardErrors() throws {
        for file in ["ControlCards.swift", "MainStatusView.swift"] {
            let source = try String(contentsOf: ui.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("try? controller."), file)
            XCTAssertTrue(source.contains("SecretRedactor.redact(error.localizedDescription)"), file)
        }
    }

    func testBrightnessKeyChoiceIsRenderedAndObserved() throws {
        let source = try String(contentsOf: ui.appendingPathComponent("ControlCards.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("BrightnessKeyRow(preferences:"))
        XCTAssertTrue(source.contains("@ObservedObject var preferences: BrightnessKeyPreferences"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Brightness keys\")"))
    }

    func testCredentialRemovalIsIndependentOfInputAndRequiresConfirmation() throws {
        let source = try String(contentsOf: ui.appendingPathComponent("SymVaultCredentialField.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("if !value.isEmpty"))
        XCTAssertTrue(source.contains(".confirmationDialog("))
        XCTAssertTrue(source.contains("role: .destructive, action: delete"))
    }

    func testReadoutAndDockChoicesAreObserved() throws {
        let source = try String(contentsOf: ui.appendingPathComponent("MenuBarVisibilityCard.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@ObservedObject var readout: ReadoutSurfacePreferences"))
        XCTAssertTrue(source.contains("@ObservedObject var hudDock: HUDDockPreferences"))
        XCTAssertTrue(source.contains("ReadoutControls(readout:"))
        XCTAssertTrue(source.contains("HUDDockRow(hudDock:"))
    }

    func testInstallButtonRequiresSupportedAppAssetAndDoesNotClaimTemporaryBinaryInstalled() throws {
        let source = try String(contentsOf: ui.appendingPathComponent("UpdateNotificationView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("supportsAutomaticInstall(assetNames:"))
        XCTAssertTrue(source.contains("installed.pathExtension == \"app\""))
        XCTAssertFalse(source.contains("if release.assets.isEmpty"))
    }
}

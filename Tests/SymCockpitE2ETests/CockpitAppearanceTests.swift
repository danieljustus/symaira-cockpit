import AppKit
import SwiftUI
import XCTest
@testable import SymCockpitUI

final class CockpitAppearanceTests: XCTestCase {
    @MainActor
    func testAppearanceAppliesToExistingAndNewWindowsAndRestoresSystem() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        let suite = "com.symaira.cockpit.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            app.appearance = previous
            defaults.removePersistentDomain(forName: suite)
        }
        let preferences = CockpitAppearancePreferences(defaults: defaults)
        XCTAssertEqual(preferences.selection, .system)
        XCTAssertNil(defaults.object(forKey: CockpitAppearancePreferences.storageKey))
        let existing = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                styleMask: [.titled], backing: .buffered, defer: false)
        existing.isReleasedWhenClosed = false
        defer { existing.close() }
        for (choice, name) in [(CockpitAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            preferences.selection = choice
            XCTAssertEqual(app.appearance?.name, name)
            XCTAssertEqual(existing.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            let newWindow = NSWindow()
            newWindow.isReleasedWhenClosed = false
            XCTAssertEqual(newWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            newWindow.close()
            XCTAssertEqual(CockpitAppearancePreferences(defaults: defaults).selection, choice)
        }
        preferences.selection = .system
        XCTAssertNil(app.appearance, "System must clear the override so later macOS changes propagate")
        XCTAssertEqual(defaults.string(forKey: CockpitAppearancePreferences.storageKey), "system")
        defaults.set("unknown-future-value", forKey: CockpitAppearancePreferences.storageKey)
        XCTAssertEqual(CockpitAppearancePreferences(defaults: defaults).selection, .system)

        let snapshot = defaults.dictionaryRepresentation()
        let preview = CockpitAppearancePreferences(defaults: nil)
        preview.selection = .dark
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, snapshot as NSDictionary)
    }

    @MainActor
    func testAppearanceRestoresInFreshProcess() throws {
        let env = ProcessInfo.processInfo.environment
        if let suite = env["COCKPIT_APPEARANCE_TEST_SUITE"] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let preferences = CockpitAppearancePreferences(defaults: defaults)
            XCTAssertEqual(preferences.selection, .dark)
            preferences.apply()
            XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
            return
        }
        let app = NSApplication.shared
        let previous = app.appearance
        let suite = "com.symaira.cockpit.appearance-restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            app.appearance = previous
            defaults.removePersistentDomain(forName: suite)
        }
        CockpitAppearancePreferences(defaults: defaults).selection = .dark
        XCTAssertTrue(defaults.synchronize())
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "SymCockpitE2ETests.CockpitAppearanceTests/testAppearanceRestoresInFreshProcess",
                           Bundle(for: Self.self).bundleURL.path]
        child.environment = env.filter { ["PATH", "HOME", "CFFIXED_USER_HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"].contains($0.key) }
        child.environment?["COCKPIT_APPEARANCE_TEST_SUITE"] = suite
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(15)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        let log = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("Executed 1 test"), "The restore probe must actually execute: \(log)")
    }
}

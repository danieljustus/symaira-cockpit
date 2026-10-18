import AppKit
import SwiftUI
import SymCockpitCore
import SymairaUpdateCheck
import XCTest
@testable import SymCockpitUI

/// Native component renders, not hardware or screen-reader acceptance.
final class CockpitDesignRenderTests: XCTestCase {
    @MainActor
    func testPassiveWorkspaceRendersBothAppearancesAndCompactLoading() async throws {
        _ = NSApplication.shared
        let cases = ["wide-light", "wide-dark", "compact-light", "compact-dark-loading"]
        for name in cases {
            let width: CGFloat = name.hasPrefix("compact") ? 620 : 1080
            let scheme: ColorScheme = name.contains("dark") ? .dark : .light
            try await render(CockpitDesignPreview(showsReadings: name != "compact-dark-loading"),
                             name: name, size: CGSize(width: width, height: 760), scheme: scheme)
        }
    }

    @MainActor
    func testPreferencesAndHUDLayoutUseIsolatedSettings() async throws {
        _ = NSApplication.shared
        let suite = "com.symaira.cockpit.render.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let manager = PreferencesManager(defaults: defaults, configPaths: ConfigPaths(env: [:], home: home))
        let preferences = PreferencesView(
            manager: manager,
            appearance: CockpitAppearancePreferences(defaults: defaults),
            autoPrefs: UserDefaultsAutoUpdatePreferenceStore(keyPrefix: suite, defaults: defaults),
            aiUsage: AIUsagePreferences(defaults: defaults), aiUsageProviders: [], onCredentialChange: {}
        ).defaultAppStorage(defaults)
        try await render(preferences, name: "preferences-light", size: CGSize(width: 640, height: 560), scheme: .light)
        try await render(preferences, name: "preferences-dark", size: CGSize(width: 640, height: 560), scheme: .dark)
        let hud = HUDContentCard(items: HUDItemPreferences(defaults: defaults), preferences: manager, dock: .notch)
            .environment(\.tunePanelChrome, .embedded)
        try await render(hud, name: "hud-compact", size: CGSize(width: 508, height: 700), scheme: .light)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "rendering must not write configuration")
    }

    @MainActor
    private func render<Content: View>(_ content: Content, name: String, size: CGSize, scheme: ColorScheme) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), name)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name)
        XCTAssertGreaterThan(png.count, 10_000, "blank native render: \(name)")
        XCTAssertEqual(host.bounds.width, size.width, "content exceeded the intended width: \(name)")
        // A standalone card may use less height than the window's budget.
        XCTAssertLessThanOrEqual(host.bounds.height, size.height, "content exceeded the intended height: \(name)")
        if let directory = ProcessInfo.processInfo.environment["COCKPIT_RENDER_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}

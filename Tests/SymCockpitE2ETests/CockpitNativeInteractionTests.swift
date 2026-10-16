import AppKit
import Observation
import SwiftUI
import SymCockpitCore
import SymairaUpdateCheck
import XCTest
@testable import SymCockpitUI

/// In-process native AX actions, not physical keyboard or VoiceOver acceptance.
final class CockpitNativeInteractionTests: XCTestCase {
    @MainActor
    func testSidebarRetainsSliderAndAppearanceButtonsApply() async throws {
        let app = NSApplication.shared
        // AppKit scroll views expose their document's AX children only while
        // an assistive client is active. Restore this process-local state.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        XCTAssertTrue(app.accessibilityIsAttributeSettable(enhancedUI))
        let previousEnhancedUI = app.accessibilityAttributeValue(enhancedUI)
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }
        let oldAppearance = app.appearance
        let oldPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        let appearance = CockpitAppearancePreferences(defaults: nil)
        let state = SliderState()
        let root = CockpitWorkspaceView(version: "test", openPreferences: {}, appearance: appearance, content: {
            SliderContent(state: state)
        })
        // An in-process test has no assistive client to enable SwiftUI's AX tree.
        // This is view-local state, not permission to control other applications.
        .environment(\.accessibilityEnabled, true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close(); app.appearance = oldAppearance; app.setActivationPolicy(oldPolicy) }
        try await Task.sleep(for: .milliseconds(200))
        let slider = try XCTUnwrap(views(window.contentView).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = 0.43
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.value, 0.43)
        for label in ["Collapse sidebar", "Expand sidebar", "Collapse sidebar", "Expand sidebar"] {
            try press(label, in: window)
            try await Task.sleep(for: .milliseconds(100))
            let current = try XCTUnwrap(views(window.contentView).compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(current === slider, "Sidebar toggle must not remount the panel or reset in-flight controls")
            XCTAssertEqual(current.doubleValue, 0.43)
        }
        XCTAssertTrue(elements(window).contains { text($0, "accessibilityIdentifier") == "cockpit-settings-menu" })

        let suite = "com.symaira.cockpit.native-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesView(
            manager: PreferencesManager(defaults: defaults), appearance: appearance,
            autoPrefs: UserDefaultsAutoUpdatePreferenceStore(keyPrefix: suite, defaults: defaults),
            aiUsage: AIUsagePreferences(defaults: defaults), aiUsageProviders: [], onCredentialChange: {})
            .defaultAppStorage(defaults)
            .environment(\.accessibilityEnabled, true)
        let settings = NSWindow(contentViewController: NSHostingController(rootView: preferences))
        settings.isReleasedWhenClosed = false
        settings.setContentSize(NSSize(width: 640, height: 560))
        settings.orderFront(nil)
        defer { settings.close() }
        try await Task.sleep(for: .milliseconds(200))
        for choice in [CockpitAppearance.dark, .light, .system] {
            try press(choice.title, in: settings)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(appearance.selection, choice)
            XCTAssertEqual(app.appearance?.name, choice.nativeAppearance?.name)
        }
    }

    @MainActor
    private func views(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { views($0) }
    }

    @MainActor
    private func text(_ object: NSObject, _ selectorName: String) -> String? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    @MainActor
    private func elements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            var children = node.responds(to: selector)
                ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
            if let window = node as? NSWindow {
                if let content = window.contentView { children.append(content) }
                children += window.toolbar?.items.compactMap(\.view) ?? []
            }
            if let view = node as? NSView { children += view.subviews }
            // Toolbar containers mirror a child's label/role but return false
            // from AXPress. Select the actual descendant control first.
            return children.flatMap(walk) + [node]
        }
        return walk(root)
    }

    @MainActor
    private func press(_ label: String, in window: NSWindow) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let nodes = elements(window)
        let button = try XCTUnwrap(nodes.first {
            text($0, "accessibilityLabel") == label
                && text($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && $0.responds(to: selector)
        }, "Missing button \(label); labels: \(nodes.compactMap { text($0, "accessibilityLabel") })")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(button.method(for: selector), to: Action.self)
        XCTAssertTrue(action(button, selector), "AX press failed: \(label)")
    }
}

@MainActor @Observable
private final class SliderState {
    var value = 0.62
}

private struct SliderContent: View {
    let state: SliderState
    var body: some View {
        TuneSliderRow(title: "Screen Brightness", systemImage: "sun.max.fill", value: state.value,
                      range: 0...1, onCommit: { state.value = $0 })
            .cardStyle()
    }
}

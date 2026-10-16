#if DEBUG
import AppKit
import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Interactive, screen-docked production HUD with explicit example values.
/// No hardware model, sampler, credentials or persistent settings are created.
@MainActor
public final class HUDDemoController: NSObject, NSWindowDelegate {
    private let dock = HUDDockPreferences(defaults: nil)
    private let items = HUDItemPreferences(defaults: nil)
    private let appearance: CockpitAppearancePreferences
    private var hud: HUDDockController?
    private var window: NSWindow?

    public init(appearance: CockpitAppearance = .system) {
        self.appearance = CockpitAppearancePreferences(defaults: nil, initialValue: appearance)
        super.init()
    }

    public func show() {
        appearance.apply()
        if hud == nil {
            if !HUDDockController.isAvailable(dock: .notch) { dock.dock = .right(.center) }
            let controller = HUDDockController(
                dockPreferences: dock, itemPreferences: items,
                resolveItems: Self.exampleValues, onDetailVisibility: { _ in }
            )
            controller.openCockpitTitle = "Demo"
            controller.openPanel = { [weak self] in self?.showControls() }
            controller.openCockpit = { [weak self] in self?.showControls() }
            hud = controller
            controller.setEnabled(true)
        }
        showControls()
    }

    public func stop() {
        hud?.setEnabled(false)
        hud = nil
    }

    private func showControls() {
        if window == nil {
            let controls = HUDDemoControls(dock: dock, appearance: appearance) { [weak self] in
                self?.hud?.setEnabled($0)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: controls))
            window.title = "Cockpit HUD Demo · Beispieldaten"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApplication.shared.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        stop()
        NSApplication.shared.terminate(nil)
    }

    static func exampleValues(_ kinds: [HUDItemKind]) -> [HUDItemValue] {
        let values: [HUDItemKind: String] = [
            .metric(.cpu): "24 %", .metric(.memory): "62 %", .metric(.disk): "48 %",
            .metric(.network): "2 MB/s", .battery: "76 %", .calendarWeek: "W 42",
            .keepAwake: "Sleep allowed", .fanProfile: "Balanced (idle)"
        ]
        return kinds.compactMap { kind in
            guard let value = values[kind] else { return nil }
            return HUDItemValue(kind: kind, title: kind.displayName, value: value,
                                symbolName: kind.symbolName, isActive: kind == .battery)
        }
    }
}

@MainActor
private struct HUDDemoControls: View {
    @ObservedObject var dock: HUDDockPreferences
    @Bindable var appearance: CockpitAppearancePreferences
    let setEnabled: (Bool) -> Void
    @State private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.large) {
            Text("HUD Demo").symairaText(.title)
            Text("Beispieldaten · Keine Hardwarezugriffe · Keine gespeicherten Änderungen")
                .symairaText(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Position", selection: $dock.dock) {
                ForEach(HUDDock.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                        .disabled(!HUDDockController.isAvailable(dock: option))
                }
            }
            .accessibilityIdentifier("hud-demo-position")
            SymairaSegmentedControl(
                "Darstellung", selection: $appearance.selection,
                options: CockpitAppearance.allCases.map { ($0, $0.title) }
            )
            Toggle("HUD anzeigen", isOn: $enabled)
                .onChange(of: enabled) { _, value in setEnabled(value) }
            Text("Maus an die Notch oder den gewählten Bildschirmrand bewegen: Vorschau. Klicken: aufklappen. Ziehen: umdocken. Panel und Demo öffnen dieses Fenster.")
                .symairaText(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Demo beenden") { NSApplication.shared.terminate(nil) }
                .symairaButtonStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(SymairaSpacing.xLarge)
        .frame(width: 520)
        .background(SymairaTokens.surface)
    }
}
#endif

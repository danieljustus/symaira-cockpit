@preconcurrency import AppKit
import SwiftUI
import SymTuneUI

/// Owns the cockpit window and the app's activation policy.
///
/// The app lives in the menu bar (`LSUIElement`), so it starts as an accessory
/// with no Dock icon. A window on an accessory app cannot be brought properly
/// forward or receive a real title bar focus, so the policy is raised to
/// `.regular` while the window is open and dropped back when it closes — the
/// Dock icon appears exactly for as long as there is a window to switch to.
@MainActor
final class CockpitWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let statusBar: StatusBarController
    private let openPreferences: () -> Void
    private let scopeModel = ScopeViewModel()
    private let operateModel = OperateViewModel()

    init(statusBar: StatusBarController, openPreferences: @escaping () -> Void) {
        self.statusBar = statusBar
        self.openPreferences = openPreferences
        super.init()
    }

    func show() {
        if let window {
            present(window)
            return
        }

        let root = CockpitRootView(
            statusBar: statusBar,
            scope: scopeModel,
            operate: operateModel,
            openPreferences: openPreferences
        )
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Symaira Cockpit"
        // The toolbar draws the current section's name centred; leaving the
        // window title on as well printed two titles side by side.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 940, height: 640))
        window.contentMinSize = NSSize(width: 780, height: 520)
        // Closing the window must not deallocate it out from under the
        // delegate; `show()` reuses the same instance.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SymCockpitMainWindow")
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The Tune panel in the window shares the menu bar's model; tell it a
        // panel is on screen so it polls at the interactive cadence.
        statusBar.setEmbeddedPanelVisible(true)
        scopeModel.setVisible(true)
        operateModel.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        statusBar.setEmbeddedPanelVisible(false)
        scopeModel.setVisible(false)
        // Back to a menu-bar-only app. Deferred, because dropping the policy
        // inside the close notification races the window teardown and can
        // leave a ghost Dock icon behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

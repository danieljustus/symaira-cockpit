@preconcurrency import AppKit
import SwiftUI
import SymCockpitUI

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
    /// The page the window shows; the main menu's Navigate items set it.
    let navigation = CockpitNavigation()

    init(statusBar: StatusBarController, openPreferences: @escaping () -> Void) {
        self.statusBar = statusBar
        self.openPreferences = openPreferences
        super.init()
    }

    /// Brings the window forward on `destination`.
    func show(_ destination: CockpitDestination) {
        navigation.selection = destination
        show()
    }

    func show() {
        if let window {
            // A closed window keeps its NSHostingController only until here:
            // re-create it on show rather than leaving a hidden SwiftUI graph
            // updating on every agent sample.
            if window.contentViewController == nil {
                window.contentViewController = makeHostingController()
            }
            present(window)
            return
        }

        let window = NSWindow(contentViewController: makeHostingController())
        window.title = "Symaira Cockpit"
        window.titleVisibility = .visible
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1080, height: 760))
        // Default sidebar plus the content reserve, the minimum of the shared shell.
        window.contentMinSize = NSSize(width: 840, height: 560)
        // Closing the window must not deallocate it out from under the
        // delegate; `show()` reuses the same instance.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SymCockpitMainWindow")
        self.window = window
        present(window)
    }

    private func makeHostingController() -> NSHostingController<CockpitRootView> {
        NSHostingController(rootView: CockpitRootView(
            statusBar: statusBar,
            openPreferences: openPreferences,
            navigation: navigation
        ))
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The Tune panel in the window shares the menu bar's model; tell it a
        // panel is on screen so it polls at the interactive cadence.
        navigation.isWindowVisible = true
        statusBar.setEmbeddedPanelVisible(true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        navigation.isWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        navigation.isWindowVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        navigation.isWindowVisible = false
        statusBar.setEmbeddedPanelVisible(false)
        // A hidden hosting view stays subscribed to the shared model and keeps
        // rebuilding the workspace off screen. Release it with the window.
        window?.contentViewController = nil
        // Back to a menu-bar-only app. Deferred, because dropping the policy
        // inside the close notification races the window teardown and can
        // leave a ghost Dock icon behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

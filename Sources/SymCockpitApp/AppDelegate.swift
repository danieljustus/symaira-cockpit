@preconcurrency import AppKit
import SymTuneUI

/// Application delegate for Symaira Cockpit.
///
/// The app is menu-bar-first: it launches as an `LSUIElement` accessory with a
/// status item and no Dock presence, exactly like the standalone Tune app. The
/// difference is the cockpit window behind it — opened from the status item's
/// context menu (or Cmd+0) — which shows all three families in one place.
///
/// The status item itself *is* Tune's ``StatusBarController``: same metrics
/// pipeline, same popover, same preferences. The cockpit embeds it rather than
/// running a second one, so the menu-bar readout and the window's Tune tab can
/// never drift apart.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var windowController: CockpitWindowController?

    /// `NSApplicationMain` only wires the delegate up from a nib, and this app
    /// has none — set it explicitly before running (same reason as SymTuneApp).
    ///
    /// `--version` prints the bundle's cockpit version and exits before AppKit
    /// starts. The GUI binary has no dispatcher CLI; release tooling uses this
    /// to check that an assembled bundle reports the tagged version without
    /// launching the event loop.
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        if arguments.contains("--version") {
            print("Symaira Cockpit \(CockpitAppVersion.current)")
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let statusBar = StatusBarController()
        statusBar.openCockpitTitle = "Open Cockpit…"
        statusBar.statusItemAccessibilityLabel = "Symaira Cockpit"
        statusBar.fallbackIconTitle = "SC"
        statusBar.preferencesWindowTitle = "Symaira Cockpit Preferences"
        statusBar.keepAwakeAssertionReason = "Symaira Cockpit"
        self.statusBarController = statusBar

        let window = CockpitWindowController(
            statusBar: statusBar,
            openPreferences: { [weak statusBar] in statusBar?.openPreferences() }
        )
        self.windowController = window

        statusBar.onOpenCockpit = { [weak window] in window?.show() }

        // A menu-bar-only app that shows nothing on first launch reads as a
        // failed launch. Open the cockpit once, then stay out of the way.
        let defaults = UserDefaults.standard
        let forced = ProcessInfo.processInfo.environment["SYMCOCKPIT_SHOW_WINDOW"] == "1"
        if forced || !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            window.show()
        }
    }

    /// Set the first time the app finishes launching; gates the one-time
    /// cockpit window. `SYMCOCKPIT_SHOW_WINDOW=1` forces it open regardless,
    /// which is what the launch smoke check uses.
    private static let hasLaunchedKey = "com.symaira.cockpit.hasLaunched"

    func applicationWillTerminate(_ notification: Notification) {
        windowController = nil
        statusBarController = nil
    }

    /// Reopening from the Dock (while the window made the app a regular app)
    /// should bring the cockpit back rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // AppKit only calls this on the main thread, but the protocol
        // requirement itself is nonisolated, so the isolation has to be
        // asserted rather than inferred.
        MainActor.assumeIsolated { windowController?.show() }
        return true
    }

    @MainActor
    @objc private func openCockpit() {
        windowController?.show()
    }

    @MainActor
    @objc private func openPreferences() {
        statusBarController?.openPreferences()
    }

    /// A minimal main menu, so the standard editing shortcuts reach the text
    /// fields in Preferences and the cockpit window has a keyboard route.
    ///
    /// An accessory app may own a main menu; `LSUIElement` governs the Dock
    /// icon independently, and the menu only shows while the app is frontmost —
    /// which is precisely when these shortcuts are wanted.
    @MainActor
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let cockpitItem = NSMenuItem(
            title: "Cockpit",
            action: #selector(openCockpit),
            keyEquivalent: "0"
        )
        cockpitItem.target = self
        appMenu.addItem(cockpitItem)

        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        appMenu.addItem(prefsItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit Symaira Cockpit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        // Undo/redo are informal selectors forwarded by NSResponder to the
        // undo manager; neither is exposed to Swift, hence the string form.
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}

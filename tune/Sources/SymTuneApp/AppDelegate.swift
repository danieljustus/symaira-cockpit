@preconcurrency import AppKit

/// Application delegate for the SymairaTune menu-bar app.
///
/// This is a status-bar-only app (LSUIElement=true) — no dock icon, no main
/// window. All user interaction happens through the menu-bar icon dropdown.
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    /// AppKit's default `@main` entry point (`NSApplicationMain`) only wires up
    /// the delegate when a main nib/storyboard instantiates it. This app has
    /// neither, so without an explicit entry point the delegate is never set
    /// and `applicationDidFinishLaunching` never runs — the app launches but
    /// creates no status item. Set the delegate manually before running.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController = nil
    }

    /// Installs a minimal main menu so that standard text-editing keyboard
    /// shortcuts (Cmd+X/C/V/A/Z) work in the app's text fields.
    ///
    /// AppKit only turns Cmd+V into a `paste:` responder-chain action (and
    /// likewise for cut/copy/select-all/undo/redo) when the app has a main
    /// menu containing menu items wired to those standard selectors. A
    /// status-item-only app that never sets `NSApp.mainMenu` has no such
    /// items, so those shortcuts silently do nothing even though the field
    /// editor itself supports them.
    ///
    /// This does not change the app's activation policy or add a Dock icon
    /// — `LSUIElement` in Info.plist still controls that independently of
    /// `NSApp.mainMenu`. An accessory app can have a main menu; it's simply
    /// not shown until the app is the active (frontmost) app, e.g. while a
    /// Preferences window has focus, which is exactly when these shortcuts
    /// are needed.
    @MainActor
    private func installMainMenu() {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        // Application menu (the bolded first menu; AppKit treats the first
        // item of the main menu specially regardless of its title).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Edit menu — standard boilerplate so Cut/Copy/Paste/Select All/
        // Undo/Redo route through the responder chain to whichever text
        // field currently has focus.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        // Undo/Redo use informal selectors: NSResponder forwards `undo:`
        // and `redo:` to the responder's `undoManager`, but neither is a
        // formal Objective-C method exposed to Swift, so they must be
        // referenced via string-based `Selector(...)` rather than `#selector`.
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

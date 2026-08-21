@preconcurrency import AppKit

/// Application delegate for the SymairaTune menu-bar app.
///
/// This is a status-bar-only app (LSUIElement=true) — no dock icon, no main
/// window. All user interaction happens through the menu-bar icon dropdown.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController = nil
    }
}

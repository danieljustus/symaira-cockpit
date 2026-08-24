import Foundation
import SwiftUI
import SymOperateCore

/// State behind the Operate section: the two TCC grants automation depends on,
/// and the inventory of apps, windows and displays it can act upon.
///
/// Nothing here *performs* automation — clicking and typing stay in the CLI and
/// the MCP server, where an agent's action policy applies. The GUI's job is to
/// answer "is this Mac set up for it, and what is on screen right now".
@MainActor
final class OperateViewModel: ObservableObject {
    @Published private(set) var permissions: PermissionSnapshot?
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var isLoading = false

    private let controller = AutomationController()

    var accessibilityGranted: Bool { permissions?.accessibilityGranted ?? false }
    var screenRecordingGranted: Bool { permissions?.screenRecordingGranted ?? false }

    /// Every reader here is synchronous AppKit/CoreGraphics work on the main
    /// thread, so this is a plain call, not a task.
    func refresh() {
        isLoading = true
        permissions = controller.permissionsStatus()
        apps = controller.listApps().sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        windows = controller.listWindows()
        displays = controller.listDisplays()
        isLoading = false
    }

    /// Opens the system prompt (or Settings pane, once the prompt has been
    /// answered once). The grant lands on the *app bundle*, which is why the
    /// GUI needs its own approval even if the CLI already has one.
    func requestAccessibility() {
        controller.requestAccessibilityPermission()
        refresh()
    }

    func requestScreenRecording() {
        controller.requestScreenRecordingPermission()
        refresh()
    }
}

import AppKit
import CoreGraphics
import Foundation

// MARK: - Screen Service

public protocol ScreenServiceProtocol {
    func listDisplays() -> [DisplayInfo]
    func captureMainDisplay(maxDimension: CGFloat) throws -> Snapshot
    func captureDisplay(displayID: UInt32, maxDimension: CGFloat) throws -> Snapshot
    func captureWindow(windowID: Int, maxDimension: CGFloat) throws -> Snapshot
}

extension ScreenServiceProtocol {
    /// Capture the main display using the standard max-dimension limit.
    public func captureMainDisplay() throws -> Snapshot {
        try captureMainDisplay(maxDimension: 1280)
    }

    /// Capture a specific display using the standard max-dimension limit.
    public func captureDisplay(displayID: UInt32) throws -> Snapshot {
        try captureDisplay(displayID: displayID, maxDimension: 1280)
    }

    /// Capture a specific window using the standard max-dimension limit.
    public func captureWindow(windowID: Int) throws -> Snapshot {
        try captureWindow(windowID: windowID, maxDimension: 1280)
    }
}

// MARK: - Accessibility Service

public protocol AccessibilityServiceProtocol {
    func queryFrontmostUI(snapshotID: String, maxDepth: Int, maxNodes: Int) throws -> [UINode]
    func resolveElement(snapshotID: String, elementID: String) -> AccessibilityService.ResolvedElement?
    func resolveElementAtPoint(x: Double, y: Double) -> AccessibilityService.ResolvedElement?
    func hasCachedNodes(for snapshotID: String) -> Bool
    func cachedNodes(for snapshotID: String) -> [UINode]?
    func cachedSnapshot(for snapshotID: String) -> Snapshot?
    func storeSnapshot(_ snapshot: Snapshot, for snapshotID: String)
    func frontmostFocusedElementRole() -> String?
    func frontmostContainsText(_ text: String) -> Bool
    /// Lightweight polling variant: caches the last frontmost PID and confirmed-absent
    /// text strings so repeated polls skip IPC for unchanged elements.
    func frontmostContainsTextPolling(_ text: String) -> Bool
    /// Reset the polling cache (e.g. when the frontmost application changes).
    func invalidatePollingCache()
    func performMenuAction(path: [String]) throws
}

extension AccessibilityServiceProtocol {
    public func frontmostContainsTextPolling(_ text: String) -> Bool {
        frontmostContainsText(text)
    }

    public func invalidatePollingCache() {}
}

// MARK: - Input Service

public protocol InputServiceProtocol {
    func click(at point: PointValue, button: String, doubleClick: Bool) throws
    func typeText(_ text: String) throws
    func pressKeys(_ keys: [String]) throws
    func scroll(deltaX: Double, deltaY: Double) throws
    func drag(from start: PointValue, to end: PointValue, steps: Int) throws
}

// MARK: - App Service

public protocol AppServiceProtocol {
    func listApps() -> [AppInfo]
    func listWindows() -> [WindowInfo]
    func frontmostApp() -> AppInfo?
    func launchApp(bundleID: String?, appName: String?) throws
    func focusWindow(bundleID: String?, appName: String?, title: String?) throws
}

// MARK: - OCR Service

public protocol OCRServiceProtocol {
    func recognizeText(in image: CGImage) -> OCRResult
    func isAXTreeWeak(nodeCount: Int, threshold: Int) -> Bool
}

extension OCRServiceProtocol {
    public func isAXTreeWeak(nodeCount: Int) -> Bool {
        isAXTreeWeak(nodeCount: nodeCount, threshold: 3)
    }
}

// MARK: - UI Query Service

public protocol UIQueryServiceProtocol {
    func findNodes(in nodes: [UINode], predicate: UIElementPredicate) -> [UINode]
}

// MARK: - Permission Service

public protocol PermissionServiceProtocol {
    func status() -> PermissionSnapshot
    func requestAccessibilityPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
}

// MARK: - History Service

public protocol HistoryServiceProtocol {
    func record(_ event: HistoryEvent) throws
    func events() throws -> [HistoryEvent]
}

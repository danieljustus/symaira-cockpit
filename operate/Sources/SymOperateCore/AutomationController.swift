import AppKit
import CoreGraphics
import Foundation

public final class AutomationController {
    private let permissions: any PermissionServiceProtocol
    private let screen: any ScreenServiceProtocol
    private let apps: any AppServiceProtocol
    let accessibility: any AccessibilityServiceProtocol
    private let input: any InputServiceProtocol
    private let ocr: any OCRServiceProtocol
    private let queryService: any UIQueryServiceProtocol
    public var actionPolicy: ActionPolicy
    private let history: any HistoryServiceProtocol

    public init(
        permissions: any PermissionServiceProtocol = PermissionService(),
        screen: any ScreenServiceProtocol = ScreenService(),
        apps: any AppServiceProtocol = AppService(),
        accessibility: any AccessibilityServiceProtocol = AccessibilityService(),
        input: any InputServiceProtocol = InputService(),
        ocr: any OCRServiceProtocol = OCRService(),
        queryService: any UIQueryServiceProtocol = UIQueryService(),
        actionPolicy: ActionPolicy = ActionPolicy(),
        history: any HistoryServiceProtocol = HistoryService()
    ) {
        self.permissions = permissions
        self.screen = screen
        self.apps = apps
        self.accessibility = accessibility
        self.input = input
        self.ocr = ocr
        self.queryService = queryService
        self.actionPolicy = actionPolicy
        self.history = history
    }

    public func permissionsStatus() -> PermissionSnapshot {
        permissions.status()
    }

    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        permissions.requestAccessibilityPermission()
    }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        permissions.requestScreenRecordingPermission()
    }

    public func listApps() -> [AppInfo] {
        apps.listApps()
    }

    public func listWindows() -> [WindowInfo] {
        apps.listWindows()
    }

    public func listDisplays() -> [DisplayInfo] {
        screen.listDisplays()
    }

    public func snapshot(displayID: UInt32? = nil, windowID: Int? = nil) throws -> Snapshot {
        try requirePermission(.capture, for: "snapshot")
        if let windowID {
            return try screen.captureWindow(windowID: windowID)
        }
        if let displayID {
            return try screen.captureDisplay(displayID: displayID)
        }
        return try screen.captureMainDisplay()
    }

    public func queryUI(maxDepth: Int = 4, maxNodes: Int = 200, displayID: UInt32? = nil, windowID: Int? = nil) throws -> UIQueryResult {
        let snapshot = try self.snapshot(displayID: displayID, windowID: windowID)
        accessibility.storeSnapshot(snapshot, for: snapshot.id)
        let nodes = try accessibility.queryFrontmostUI(snapshotID: snapshot.id, maxDepth: maxDepth, maxNodes: maxNodes)
        return UIQueryResult(snapshot: snapshot, app: apps.frontmostApp(), nodes: nodes)
    }

    public func queryUIWithOCR(maxDepth: Int = 4, maxNodes: Int = 200, displayID: UInt32? = nil, windowID: Int? = nil) throws -> UIQueryResultWithOCR {
        let snapshot = try self.snapshot(displayID: displayID, windowID: windowID)
        accessibility.storeSnapshot(snapshot, for: snapshot.id)
        let nodes = try accessibility.queryFrontmostUI(snapshotID: snapshot.id, maxDepth: maxDepth, maxNodes: maxNodes)
        let isWeak = ocr.isAXTreeWeak(nodeCount: countNodes(nodes))

        var ocrResult: OCRResult?
        if isWeak, let imageData = Data(base64Encoded: snapshot.imageBase64PNG) {
            if let bitmapRep = NSBitmapImageRep(data: imageData),
               let cgImage = bitmapRep.cgImage {
                ocrResult = ocr.recognizeText(in: cgImage)
            }
        }

        return UIQueryResultWithOCR(
            snapshot: snapshot,
            app: apps.frontmostApp(),
            nodes: nodes,
            ocrResult: ocrResult,
            axTreeWeak: isWeak
        )
    }

    private func countNodes(_ nodes: [UINode]) -> Int {
        var count = 0
        var stack = nodes
        while !stack.isEmpty {
            let node = stack.removeLast()
            count += 1
            stack.append(contentsOf: node.children)
        }
        return count
    }

    public func findUI(
        predicate: UIElementPredicate,
        snapshotID: String? = nil,
        maxDepth: Int = 4,
        maxNodes: Int = 200,
        displayID: UInt32? = nil,
        windowID: Int? = nil
    ) throws -> UIQueryResult {
        try requirePermission(.capture, for: "find_ui")
        let queryResult: UIQueryResult
        if let snapshotID, accessibility.hasCachedNodes(for: snapshotID),
           let cachedNodes = accessibility.cachedNodes(for: snapshotID),
           let cachedSnapshot = accessibility.cachedSnapshot(for: snapshotID) {
            // Reuse existing snapshot — run the query against cached tree
            let matched = queryService.findNodes(in: cachedNodes, predicate: predicate)
            return UIQueryResult(snapshot: cachedSnapshot, app: apps.frontmostApp(), nodes: matched)
        } else {
            queryResult = try queryUI(maxDepth: maxDepth, maxNodes: maxNodes, displayID: displayID, windowID: windowID)
        }
        let matched = queryService.findNodes(in: queryResult.nodes, predicate: predicate)
        return UIQueryResult(snapshot: queryResult.snapshot, app: queryResult.app, nodes: matched)
    }

    private func executeAction(
        name: String,
        targets: [String: String] = [:],
        action: () throws -> String
    ) throws -> ActionResult {
        do {
            let message = try action()
            let result = ActionResult(ok: true, message: message, snapshot: try? screen.captureMainDisplay())
            try? history.record(HistoryEvent(action: name, targets: targets, success: true, message: message))
            return result
        } catch {
            try? history.record(HistoryEvent(action: name, targets: targets, success: false, message: error.localizedDescription))
            throw error
        }
    }

    public func click(
        snapshotID: String? = nil,
        elementID: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        button: String = "left",
        doubleClick: Bool = false
    ) throws -> ActionResult {
        try requirePermission(.input, for: "click")
        var targets: [String: String] = ["button": button, "doubleClick": String(doubleClick)]
        if let snapshotID { targets["snapshotID"] = snapshotID }
        if let elementID { targets["elementID"] = elementID }
        if let x { targets["x"] = String(x) }
        if let y { targets["y"] = String(y) }

        return try executeAction(name: "click", targets: targets) {
            let target = try resolvePoint(snapshotID: snapshotID, elementID: elementID, x: x, y: y)
            try input.click(at: target, button: button, doubleClick: doubleClick)
            return "Click event posted at (\(Int(target.x)), \(Int(target.y)))."
        }
    }

    public func typeText(_ text: String) throws -> ActionResult {
        try requirePermission(.input, for: "type_text")
        let redacted = "<redacted: \(text.count) chars>"
        return try executeAction(name: "type_text", targets: ["text": redacted]) {
            guard !text.isEmpty else {
                throw AutomationError.invalidArgument("type_text requires a non-empty text argument.")
            }
            try guardAgainstSecureField()
            try input.typeText(text)
            return "\(text.count) keystroke events posted."
        }
    }

    public func pressKeys(_ keys: [String]) throws -> ActionResult {
        try requirePermission(.input, for: "press_keys")
        return try executeAction(name: "press_keys", targets: ["keys": keys.joined(separator: "+")]) {
            try guardAgainstSecureField()
            try input.pressKeys(keys)
            return "Key events posted: \(keys.joined(separator: "+"))."
        }
    }

    public func scroll(deltaX: Double = 0, deltaY: Double) throws -> ActionResult {
        try requirePermission(.input, for: "scroll")
        return try executeAction(name: "scroll", targets: ["deltaX": String(deltaX), "deltaY": String(deltaY)]) {
            try input.scroll(deltaX: deltaX, deltaY: deltaY)
            return "Scroll event posted with delta (\(deltaX), \(deltaY))."
        }
    }

    public func drag(
        snapshotID: String? = nil,
        fromElementID: String? = nil,
        toElementID: String? = nil,
        fromX: Double? = nil,
        fromY: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil
    ) throws -> ActionResult {
        try requirePermission(.input, for: "drag")
        var targets: [String: String] = [:]
        if let snapshotID { targets["snapshotID"] = snapshotID }
        if let fromElementID { targets["fromElementID"] = fromElementID }
        if let toElementID { targets["toElementID"] = toElementID }
        if let fromX { targets["fromX"] = String(fromX) }
        if let fromY { targets["fromY"] = String(fromY) }
        if let toX { targets["toX"] = String(toX) }
        if let toY { targets["toY"] = String(toY) }

        return try executeAction(name: "drag", targets: targets) {
            let start = try resolvePoint(snapshotID: snapshotID, elementID: fromElementID, x: fromX, y: fromY)
            let end = try resolvePoint(snapshotID: snapshotID, elementID: toElementID, x: toX, y: toY)
            try input.drag(from: start, to: end, steps: 24)
            return "Drag event posted from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))."
        }
    }

    public func launchApp(bundleID: String? = nil, appName: String? = nil) throws -> ActionResult {
        try requirePermission(.appControl, for: "launch_app")
        var targets: [String: String] = [:]
        if let bundleID { targets["bundleID"] = bundleID }
        if let appName { targets["appName"] = appName }

        return try executeAction(name: "launch_app", targets: targets) {
            try apps.launchApp(bundleID: bundleID, appName: appName)
            return "Application launch requested."
        }
    }

    public func focusWindow(bundleID: String? = nil, appName: String? = nil, title: String? = nil) throws -> ActionResult {
        try requirePermission(.appControl, for: "focus_window")
        var targets: [String: String] = [:]
        if let bundleID { targets["bundleID"] = bundleID }
        if let appName { targets["appName"] = appName }
        if let title { targets["title"] = title }

        return try executeAction(name: "focus_window", targets: targets) {
            try apps.focusWindow(bundleID: bundleID, appName: appName, title: title)
            return "Window-focus request dispatched."
        }
    }

    public func menuAction(path: [String]) throws -> ActionResult {
        try requirePermission(.menuAction, for: "menu_action")
        return try executeAction(name: "menu_action", targets: ["path": path.joined(separator: " > ")]) {
            try accessibility.performMenuAction(path: path)
            return "Menu action posted: \(path.joined(separator: " > "))."
        }
    }

    public func waitFor(text: String?, app: String?, timeoutSeconds: Double = 10) async throws -> ActionResult {
        accessibility.invalidatePollingCache()

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [accessibility] _ in
            accessibility.invalidatePollingCache()
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let app, !app.isEmpty {
                let exists = apps.listApps().contains {
                    $0.localizedName.localizedCaseInsensitiveContains(app) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(app) ?? false)
                }
                if exists {
                    return ActionResult(ok: true, message: "Observed app '\(app)'.", snapshot: try? screen.captureMainDisplay())
                }
            }

            if let text, !text.isEmpty, accessibility.frontmostContainsTextPolling(text) {
                return ActionResult(ok: true, message: "Observed text '\(text)'.", snapshot: try? screen.captureMainDisplay())
            }

            try await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds
        }

        throw AutomationError.operationFailed("Condition was not met within \(timeoutSeconds) seconds.")
    }

    private func guardAgainstSecureField() throws {
        if let role = accessibility.frontmostFocusedElementRole(), role == "AXSecureTextField" {
            throw AutomationError.permissionDenied("Refusing to type into a secure text field.")
        }
    }

    /// Throws a classified `.permissionDenied` refusal when `required` is not
    /// present in `actionPolicy.grantedPermissions`. The destructive-keyword
    /// guard inside `firstViolation` always takes precedence and is unchanged;
    /// this gate is ADDITIONAL to it.
    private func requirePermission(_ required: PermissionFlags, for action: String) throws {
        if let violation = actionPolicy.firstViolation(requiredPermission: required) {
            let names = violation.flagNames.joined(separator: ", ")
            throw AutomationError.permissionDenied(
                "Permission denied: the '\(names)' permission is required for \(action)."
            )
        }
    }

    private func resolvePoint(snapshotID: String?, elementID: String?, x: Double?, y: Double?) throws -> PointValue {
        if let snapshotID, let elementID {
            if let resolved = accessibility.resolveElement(snapshotID: snapshotID, elementID: elementID) {
                if let role = resolved.role, role == "AXSecureTextField" {
                    throw AutomationError.permissionDenied("Refusing to target a secure text field.")
                }

                if actionPolicy.isDestructive(role: resolved.role, title: resolved.title, label: resolved.label, value: resolved.value) {
                    throw AutomationError.permissionDenied("Refusing to target a potentially destructive UI element.")
                }

                if let frame = resolved.frame {
                    return frame.center
                }
                throw AutomationError.unavailable("The target element does not expose a clickable frame.")
            }
            throw AutomationError.staleReference("The referenced snapshot has expired or the element no longer exists.")
        }

        if let x, let y {
            if let resolved = accessibility.resolveElementAtPoint(x: x, y: y) {
                if let role = resolved.role, role == "AXSecureTextField" {
                    throw AutomationError.permissionDenied("Refusing to target a secure text field via raw coordinates.")
                }
                if actionPolicy.isDestructive(role: resolved.role, title: resolved.title, label: resolved.label, value: resolved.value) {
                    throw AutomationError.permissionDenied("Refusing to target a potentially destructive UI element via raw coordinates.")
                }
                return PointValue(x: x, y: y)
            }
            throw AutomationError.permissionDenied("Cannot identify the element at the given coordinates. Use snapshot_id + element_id instead, or take a snapshot first to enable coordinate-based targeting.")
        }

        throw AutomationError.invalidArgument("Provide either x/y coordinates or snapshot_id + element_id.")
    }
}

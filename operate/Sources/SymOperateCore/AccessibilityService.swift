import AppKit
import ApplicationServices
import Foundation

public final class AccessibilityService: AccessibilityServiceProtocol {
    public struct ResolvedElement {
        public let element: AXUIElement
        public let frame: RectValue?
        public let role: String?
        public let title: String?
        public let label: String?
        public let value: String?
        public let actions: [String]
        public let enabled: Bool?

        public init(
            element: AXUIElement,
            frame: RectValue?,
            role: String?,
            title: String?,
            label: String?,
            value: String?,
            actions: [String] = [],
            enabled: Bool? = nil
        ) {
            self.element = element
            self.frame = frame
            self.role = role
            self.title = title
            self.label = label
            self.value = value
            self.actions = actions
            self.enabled = enabled
        }
    }

    internal var elementCache: [String: [String: ResolvedElement]] = [:]
    internal var nodesCache: [String: [UINode]] = [:]
    internal var snapshotCache: [String: Snapshot] = [:]
    internal var cacheOrder: [String] = []
    private let maxCacheSnapshots = 20
    internal var testFocusedRoleOverride: String?

    // Polling cache: avoids full AX walks when the frontmost PID hasn't changed
    // and we already confirmed the text is absent.
    internal var pollingCachePID: pid_t?
    internal var pollingAbsentTexts: Set<String> = []

    public init() {}

    private func evictIfNeeded() {
        guard cacheOrder.count >= maxCacheSnapshots else { return }
        let removeCount = cacheOrder.count - maxCacheSnapshots + 1
        let toRemove = Array(cacheOrder.prefix(removeCount))
        cacheOrder.removeFirst(removeCount)
        for snapshotID in toRemove {
            elementCache.removeValue(forKey: snapshotID)
            nodesCache.removeValue(forKey: snapshotID)
            snapshotCache.removeValue(forKey: snapshotID)
        }
    }

    public func queryFrontmostUI(snapshotID: String, maxDepth: Int = 4, maxNodes: Int = 200) throws -> [UINode] {
        guard AXIsProcessTrusted() else {
            throw AutomationError.permissionDenied("Accessibility permission is required for query_ui.")
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AutomationError.notFound("No frontmost application is available.")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let roots = preferredRoots(for: axApp)
        return queryNodes(roots: roots, snapshotID: snapshotID, maxDepth: maxDepth, maxNodes: maxNodes)
    }

    /// Queries only the requested window in its owning process. Unlike the
    /// frontmost query, this never consults NSWorkspace.frontmostApplication
    /// or the focused window, so a background target cannot silently resolve
    /// against an unrelated application.
    public func queryUI(
        snapshotID: String,
        processID: Int32,
        windowID: Int,
        windowBounds: RectValue,
        maxDepth: Int,
        maxNodes: Int
    ) throws -> [UINode] {
        guard AXIsProcessTrusted() else {
            throw AutomationError.permissionDenied("Accessibility permission is required for query_ui.")
        }
        guard processID > 0 else {
            throw AutomationError.unavailable("The owner process for window \(windowID) is not resolvable.")
        }

        let axApp = AXUIElementCreateApplication(processID)
        guard let windows = axCopyElements(axApp, attribute: kAXWindowsAttribute),
              let targetWindow = windows.first(where: { axFrameMatches($0, target: windowBounds) })
        else {
            throw AutomationError.unavailable("Window \(windowID) is no longer accessible in its owning process.")
        }

        return queryNodes(roots: [targetWindow], snapshotID: snapshotID, maxDepth: maxDepth, maxNodes: maxNodes)
    }

    private func queryNodes(
        roots: [AXUIElement],
        snapshotID: String,
        maxDepth: Int,
        maxNodes: Int
    ) -> [UINode] {
        var remaining = maxNodes
        var cache: [String: ResolvedElement] = [:]
        let nodes = roots.compactMap { buildNode(element: $0, depth: 0, maxDepth: maxDepth, remainingNodes: &remaining, cache: &cache) }
        evictIfNeeded()
        elementCache[snapshotID] = cache
        nodesCache[snapshotID] = nodes
        cacheOrder.append(snapshotID)
        return nodes
    }

    private func axFrameMatches(_ element: AXUIElement, target: RectValue) -> Bool {
        guard let frame = axCopyFrame(element) else { return false }
        let tolerance = 2.0
        return abs(frame.x - target.x) <= tolerance
            && abs(frame.y - target.y) <= tolerance
            && abs(frame.width - target.width) <= tolerance
            && abs(frame.height - target.height) <= tolerance
    }

    public func resolveElement(snapshotID: String, elementID: String) -> ResolvedElement? {
        elementCache[snapshotID]?[elementID]
    }

    public func performElementAction(snapshotID: String, elementID: String, action: String) throws {
        guard let resolved = resolveElement(snapshotID: snapshotID, elementID: elementID) else {
            throw AutomationError.staleReference("The referenced snapshot has expired or the element no longer exists.")
        }
        guard resolved.enabled != false else {
            throw AutomationError.unsupported("The target UI element is disabled.")
        }
        guard resolved.actions.contains(action) else {
            throw AutomationError.unsupported("The target UI element does not expose the '\(action)' semantic action.")
        }
        let result = AXUIElementPerformAction(resolved.element, action as CFString)
        guard result == .success else {
            throw AutomationError.operationFailed("The Accessibility action '\(action)' could not be performed.")
        }
    }

    public func hasCachedNodes(for snapshotID: String) -> Bool {
        nodesCache[snapshotID] != nil
    }

    public func cachedNodes(for snapshotID: String) -> [UINode]? {
        nodesCache[snapshotID]
    }

    public func cachedSnapshot(for snapshotID: String) -> Snapshot? {
        snapshotCache[snapshotID]
    }

    public func storeSnapshot(_ snapshot: Snapshot, for snapshotID: String) {
        snapshotCache[snapshotID] = snapshot
    }

    /// Find the most specific (smallest-frame) cached element whose frame contains the given point.
    /// Returns `nil` when no cached element matches — the caller should refuse the action.
    public func resolveElementAtPoint(x: Double, y: Double) -> ResolvedElement? {
        var bestMatch: ResolvedElement?
        var bestArea: Double = .greatestFiniteMagnitude

        for snapshotCache in elementCache.values {
            for element in snapshotCache.values {
                guard let frame = element.frame else { continue }
                let minX = frame.x
                let maxX = frame.x + frame.width
                let minY = frame.y
                let maxY = frame.y + frame.height
                if x >= minX, x <= maxX, y >= minY, y <= maxY {
                    let area = frame.width * frame.height
                    if area < bestArea {
                        bestArea = area
                        bestMatch = element
                    }
                }
            }
        }
        return bestMatch
    }

    public func frontmostFocusedElementRole() -> String? {
        if let override = testFocusedRoleOverride { return override }
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedElement = axCopyElement(axApp, attribute: kAXFocusedUIElementAttribute) else { return nil }
        return axCopyString(focusedElement, attribute: kAXRoleAttribute)
    }

    public func frontmostContainsText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var seen = 0
        return searchText(in: axApp, needle: text.lowercased(), remainingDepth: 6, seen: &seen, maxNodes: 300)
    }

    public func containsText(_ text: String, processID: Int32) -> Bool {
        guard AXIsProcessTrusted(), processID > 0 else { return false }
        let axApp = AXUIElementCreateApplication(processID)
        var seen = 0
        return searchText(in: axApp, needle: text.lowercased(), remainingDepth: 6, seen: &seen, maxNodes: 300)
    }

    public func frontmostContainsTextPolling(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        let needle = text.lowercased()

        if pid == pollingCachePID, pollingAbsentTexts.contains(needle) {
            return false
        }

        if pid != pollingCachePID {
            pollingCachePID = pid
            pollingAbsentTexts.removeAll()
        }

        let axApp = AXUIElementCreateApplication(pid)
        var seen = 0
        let found = searchText(in: axApp, needle: needle, remainingDepth: 3, seen: &seen, maxNodes: 50)

        if !found {
            pollingAbsentTexts.insert(needle)
        }
        return found
    }

    public func invalidatePollingCache() {
        pollingCachePID = nil
        pollingAbsentTexts.removeAll()
    }

    public func performMenuAction(path: [String]) throws {
        try performMenuAction(path: path, processID: nil)
    }

    public func performMenuAction(path: [String], processID: Int32) throws {
        try performMenuAction(path: path, processID: Optional(processID))
    }

    private func performMenuAction(path: [String], processID: Int32?) throws {
        guard AXIsProcessTrusted() else {
            throw AutomationError.permissionDenied("Accessibility permission is required for menu_action.")
        }
        guard !path.isEmpty else {
            throw AutomationError.invalidArgument("menu_action requires a non-empty path.")
        }
        let resolvedPID: Int32
        if let processID {
            resolvedPID = processID
        } else if let app = NSWorkspace.shared.frontmostApplication {
            resolvedPID = app.processIdentifier
        } else {
            throw AutomationError.notFound("No frontmost application is available.")
        }

        let axApp = AXUIElementCreateApplication(resolvedPID)
        guard let menuBar = axCopyElement(axApp, attribute: kAXMenuBarAttribute) else {
            throw AutomationError.notFound("The target application does not expose an accessible menu bar.")
        }

        let destructiveKeywords = ActionPolicy.defaultDenyKeywords

        var current = menuBar
        for (index, segment) in path.enumerated() {
            guard let next = findMenuChild(parent: current, title: segment) else {
                throw AutomationError.notFound("Menu segment '\(segment)' was not found.")
            }
            current = next
            if index == path.count - 1 {
                if let title = axCopyString(current, attribute: kAXTitleAttribute)?.lowercased() {
                    for keyword in destructiveKeywords where title.contains(keyword) {
                            throw AutomationError.permissionDenied("Refusing to perform a destructive menu action.")
                        }
                }
                let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
                guard result == .success else {
                    throw AutomationError.operationFailed("Failed to activate menu item '\(segment)'.")
                }
            } else {
                _ = AXUIElementPerformAction(current, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.12)
            }
        }
    }

    private func preferredRoots(for axApp: AXUIElement) -> [AXUIElement] {
        if let focusedWindow = axCopyElement(axApp, attribute: kAXFocusedWindowAttribute) {
            return [focusedWindow]
        }
        if let windows = axCopyElements(axApp, attribute: kAXWindowsAttribute), !windows.isEmpty {
            return windows
        }
        return [axApp]
    }

    private func buildNode(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        remainingNodes: inout Int,
        cache: inout [String: ResolvedElement]
    ) -> UINode? {
        guard remainingNodes > 0 else { return nil }
        remainingNodes -= 1

        let id = UUID().uuidString
        let role = axCopyString(element, attribute: kAXRoleAttribute)
        let subrole = axCopyString(element, attribute: kAXSubroleAttribute)
        let title = axCopyString(element, attribute: kAXTitleAttribute)
        let label = axCopyString(element, attribute: kAXDescriptionAttribute) ?? axCopyString(element, attribute: kAXIdentifierAttribute)
        let value = axStringify(axCopyAttribute(element, attribute: kAXValueAttribute))
        let nodeDescription = axCopyString(element, attribute: kAXHelpAttribute)
        let frame = axCopyFrame(element)
        let actions = axCopyActionNames(element)
        let enabled = axBoolify(axCopyAttribute(element, attribute: kAXEnabledAttribute))

        cache[id] = ResolvedElement(
            element: element,
            frame: frame,
            role: role,
            title: title,
            label: label,
            value: value,
            actions: actions,
            enabled: enabled
        )

        let children: [UINode]
        if depth < maxDepth, let rawChildren = axCopyElements(element, attribute: kAXChildrenAttribute) {
            children = rawChildren.compactMap {
                buildNode(element: $0, depth: depth + 1, maxDepth: maxDepth, remainingNodes: &remainingNodes, cache: &cache)
            }
        } else {
            children = []
        }

        return UINode(
            id: id,
            role: role,
            subrole: subrole,
            title: title,
            label: label,
            value: value,
            nodeDescription: nodeDescription,
            frame: frame,
            actions: actions,
            enabled: enabled,
            children: children
        )
    }

    internal func searchText(in element: AXUIElement, needle: String, remainingDepth: Int, seen: inout Int, maxNodes: Int) -> Bool {
        seen += 1
        if seen > maxNodes { return false }
        let haystacks = [
            axCopyString(element, attribute: kAXTitleAttribute),
            axCopyString(element, attribute: kAXDescriptionAttribute),
            axCopyString(element, attribute: kAXHelpAttribute),
            axStringify(axCopyAttribute(element, attribute: kAXValueAttribute)),
        ].compactMap { $0?.lowercased() }

        if haystacks.contains(where: { $0.contains(needle) }) {
            return true
        }

        guard remainingDepth > 0, let children = axCopyElements(element, attribute: kAXChildrenAttribute) else {
            return false
        }

        for child in children where searchText(in: child, needle: needle, remainingDepth: remainingDepth - 1, seen: &seen, maxNodes: maxNodes) {
            return true
        }
        return false
    }

    private func findMenuChild(parent: AXUIElement, title: String) -> AXUIElement? {
        let normalized = title.lowercased()

        let immediateChildren = (axCopyElements(parent, attribute: kAXChildrenAttribute) ?? [])
            + (axCopyElements(parent, attribute: kAXMenuBarAttribute) ?? [])
            + (axCopyElements(parent, attribute: "AXMenu") ?? [])
            + (axCopyElements(parent, attribute: kAXContentsAttribute) ?? [])

        for child in immediateChildren {
            let options = [
                axCopyString(child, attribute: kAXTitleAttribute),
                axCopyString(child, attribute: kAXDescriptionAttribute),
            ].compactMap { $0?.lowercased() }
            if options.contains(where: { $0 == normalized || $0.contains(normalized) }) {
                return child
            }
            if let submenu = axCopyElement(child, attribute: "AXMenu") {
                let submenuOptions = [
                    axCopyString(submenu, attribute: kAXTitleAttribute),
                    axCopyString(submenu, attribute: kAXDescriptionAttribute),
                ].compactMap { $0?.lowercased() }
                if submenuOptions.contains(where: { $0 == normalized || $0.contains(normalized) }) {
                    return submenu
                }
            }
        }

        return nil
    }
}

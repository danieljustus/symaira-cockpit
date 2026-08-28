import Foundation

/// Explicit identity selectors for an application and, optionally, one of its windows.
///
/// When all fields are nil, callers retain the historical frontmost behavior. Once a
/// field is supplied, resolution is strict: the requested process, bundle, app name,
/// and window must all describe the same live target.
public struct TargetIdentity: Codable, Sendable, Equatable {
    public let processID: Int32?
    public let bundleID: String?
    public let appName: String?
    public let windowID: Int?
    public let windowTitle: String?

    public init(
        processID: Int32? = nil,
        bundleID: String? = nil,
        appName: String? = nil,
        windowID: Int? = nil,
        windowTitle: String? = nil
    ) {
        self.processID = processID
        self.bundleID = bundleID
        self.appName = appName
        self.windowID = windowID
        self.windowTitle = windowTitle
    }

    public var isExplicit: Bool {
        processID != nil || nonEmpty(bundleID) || nonEmpty(appName) || windowID != nil || nonEmpty(windowTitle)
    }

    private func nonEmpty(_ value: String?) -> Bool {
        value?.isEmpty == false
    }
}

/// A strict resolution result used internally by observation and action APIs.
public struct ResolvedTarget: Codable, Sendable {
    public let identity: TargetIdentity
    public let app: AppInfo
    public let window: WindowInfo?

    public init(identity: TargetIdentity, app: AppInfo, window: WindowInfo?) {
        self.identity = identity
        self.app = app
        self.window = window
    }
}


enum TargetResolver {
    static func resolve(
        _ requested: TargetIdentity,
        apps: [AppInfo],
        windows: [WindowInfo],
        frontmostWindow: (Int32, String?) -> WindowInfo?
    ) throws -> ResolvedTarget {
        guard requested.isExplicit else {
            throw AutomationError.invalidArgument("An explicit target identity is required for target resolution.")
        }

        let appMatches = apps.filter { app in
            if let processID = requested.processID, app.processIdentifier != processID { return false }
            if let bundleID = requested.bundleID, !bundleID.isEmpty, app.bundleIdentifier != bundleID { return false }
            if let appName = requested.appName, !appName.isEmpty,
               app.localizedName.localizedCaseInsensitiveCompare(appName) != .orderedSame { return false }
            return true
        }

        if let windowID = requested.windowID {
            guard let window = windows.first(where: { $0.windowID == windowID }) else {
                throw AutomationError.notFound("Window \(windowID) was not found or is no longer available.")
            }
            if let processID = requested.processID, window.ownerPID != processID {
                throw AutomationError.targetMismatch("Window \(windowID) belongs to process \(window.ownerPID), not requested process \(processID).")
            }
            if let title = requested.windowTitle, !title.isEmpty,
               window.title?.localizedCaseInsensitiveContains(title) != true {
                throw AutomationError.targetMismatch("Window \(windowID) does not match requested title '\(title)'.")
            }
            let ownerApps = appMatches.filter { $0.processIdentifier == window.ownerPID }
            if !appMatches.isEmpty && ownerApps.isEmpty {
                throw AutomationError.targetMismatch("Window \(windowID) does not belong to the requested application identity.")
            }
            let app = ownerApps.first ?? apps.first(where: { $0.processIdentifier == window.ownerPID })
                ?? AppInfo(localizedName: window.ownerName, bundleIdentifier: nil, processIdentifier: window.ownerPID, isActive: false)
            return ResolvedTarget(identity: requested, app: app, window: window)
        }

        var candidates = appMatches
        if let title = requested.windowTitle, !title.isEmpty {
            let titleWindows = windows.filter { window in
                window.title?.localizedCaseInsensitiveContains(title) == true
            }
            if requested.processID != nil || requested.bundleID != nil || requested.appName != nil {
                let pids = Set(candidates.map(\.processIdentifier))
                candidates = candidates.filter { pids.contains($0.processIdentifier) }
                let matchingWindows = titleWindows.filter { pids.contains($0.ownerPID) }
                guard !matchingWindows.isEmpty else {
                    throw AutomationError.notFound("No window matched requested title '\(title)'.")
                }
            } else if candidates.isEmpty {
                let pids = Set(titleWindows.map(\.ownerPID))
                candidates = apps.filter { pids.contains($0.processIdentifier) }
            }
        }
        guard !candidates.isEmpty else {
            throw AutomationError.notFound("No running application matched the requested target identity.")
        }
        guard candidates.count == 1 else {
            throw AutomationError.targetAmbiguous("The requested target identity matched multiple applications; provide process_id or bundle_id.")
        }
        let app = candidates[0]
        let window: WindowInfo?
        if let title = requested.windowTitle, !title.isEmpty {
            let matches = windows.filter {
                $0.ownerPID == app.processIdentifier && $0.title?.localizedCaseInsensitiveContains(title) == true
            }
            guard !matches.isEmpty else { throw AutomationError.notFound("No window matched requested title '\(title)'.") }
            guard matches.count == 1 else {
                throw AutomationError.targetAmbiguous("The requested window title matched multiple windows; provide window_id.")
            }
            window = matches[0]
        } else {
            window = frontmostWindow(app.processIdentifier, nil)
        }
        return ResolvedTarget(identity: requested, app: app, window: window)
    }
}

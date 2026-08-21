import Foundation

/// Granular permission flags for automation actions.
///
/// Each flag represents a category of automation operation that can be
/// independently allowed or denied. Used by `ActionPolicy` and surfaced
/// in safety refusals so agents can classify denials without string-matching.
public struct PermissionFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let capture           = PermissionFlags(rawValue: 1 << 0)
    public static let input             = PermissionFlags(rawValue: 1 << 1)
    public static let appControl        = PermissionFlags(rawValue: 1 << 2)
    public static let menuAction        = PermissionFlags(rawValue: 1 << 3)
    public static let destructiveAction = PermissionFlags(rawValue: 1 << 4)
    public static let secureFieldAccess = PermissionFlags(rawValue: 1 << 5)
    public static let policyModify      = PermissionFlags(rawValue: 1 << 6)
    /// All currently defined permission flags.
    public static let all: PermissionFlags = [
        .capture, .input, .appControl, .menuAction,
        .destructiveAction, .secureFieldAccess, .policyModify,
    ]
}

public struct ActionPolicy: Codable, Sendable {
    public var extraDenyKeywords: Set<String>
    public var allowedKeywords: Set<String>
    public var allowedBundleIDs: Set<String>
    /// The set of permissions granted to the calling agent.
    /// Defaults to all current flags; agents may restrict with `set_policy`.
    public var grantedPermissions: PermissionFlags

    public init(
        extraDenyKeywords: Set<String> = [],
        allowedKeywords: Set<String> = [],
        allowedBundleIDs: Set<String> = [],
        grantedPermissions: PermissionFlags = .all
    ) {
        self.extraDenyKeywords = extraDenyKeywords
        self.allowedKeywords = allowedKeywords
        self.allowedBundleIDs = allowedBundleIDs
        self.grantedPermissions = grantedPermissions
    }

    static let defaultDenyKeywords: Set<String> = [
        "delete", "remove", "erase", "clear", "trash",
        "uninstall", "allow", "authorize", "unlock",
        "quit", "terminate", "force quit", "shutdown"
    ]

    /// Returns the first violated permission flag, or `nil` if the action is permitted.
    ///
    /// Evaluates keyword-based deny/allow rules first (backward-compatible),
    /// then checks the granted permissions for the relevant operation category.
    public func firstViolation(
        role: String? = nil, title: String? = nil, label: String? = nil, value: String? = nil,
        bundleID: String? = nil, requiredPermission: PermissionFlags? = nil
    ) -> PermissionFlags? {
        // Bundle allowlist bypasses everything.
        if let bundleID, allowedBundleIDs.contains(bundleID) {
            return nil
        }

        let allDenyKeywords = Self.defaultDenyKeywords.union(extraDenyKeywords)
        let inputs = [role, title, label, value].compactMap { $0?.lowercased() }
        for input in inputs {
            for keyword in allDenyKeywords {
                if input.contains(keyword) {
                    let keywordBase = String(keyword.prefix(while: { $0 != " " }))
                    if allowedKeywords.contains(keywordBase) {
                        continue
                    }
                    return .destructiveAction
                }
            }
        }

        // Check specific permission if requested.
        if let requiredPermission, !grantedPermissions.contains(requiredPermission) {
            return requiredPermission
        }

        return nil
    }

    /// Returns `true` if the target is destructive (backward-compatible).
    /// Internally delegates to `firstViolation(…)`.
    public func isDestructive(role: String?, title: String?, label: String?, value: String?, bundleID: String? = nil) -> Bool {
        firstViolation(role: role, title: title, label: label, value: value, bundleID: bundleID) == .destructiveAction
    }

    public mutating func addDenyKeyword(_ keyword: String) {
        extraDenyKeywords.insert(keyword.lowercased())
    }

    public mutating func allowKeyword(_ keyword: String) {
        allowedKeywords.insert(keyword.lowercased())
    }

    public mutating func allowBundleID(_ bundleID: String) {
        allowedBundleIDs.insert(bundleID)
    }
}

// MARK: - Flag name mapping

extension PermissionFlags {
    /// Canonical human-readable names of all defined flags, in bit order.
    public static let allFlagNames: [String] = [
        "capture", "input", "app_control", "menu_action",
        "destructive_action", "secure_field_access", "policy_modify",
    ]

    /// Returns the flag for a human-readable name, or `nil` for unknown names.
    public static func flag(named name: String) -> PermissionFlags? {
        switch name.lowercased() {
        case "capture": return .capture
        case "input": return .input
        case "app_control": return .appControl
        case "menu_action": return .menuAction
        case "destructive_action": return .destructiveAction
        case "secure_field_access": return .secureFieldAccess
        case "policy_modify": return .policyModify
        default: return nil
        }
    }

    /// Parses an array of flag names into a set. Unknown names are ignored.
    public static func parse(names: [String]) -> PermissionFlags {
        var result = PermissionFlags()
        for name in names {
            if let flag = flag(named: name) {
                result.insert(flag)
            }
        }
        return result
    }

    /// Human-readable names of the flags present in this set, in canonical order.
    public var flagNames: [String] {
        Self.allFlagNames.filter { name in
            guard let flag = Self.flag(named: name) else { return false }
            return contains(flag)
        }
    }
}

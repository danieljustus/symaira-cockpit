import Foundation

/// Resolves the permission ceiling applied when an operate process starts.
///
/// A `--grant` value is authoritative when present. Otherwise the optional
/// `~/.config/symoperate/policy.json` file is read. With neither source, the
/// historical full-grant behavior is retained.
public enum StartupPolicy {
    public static var defaultPolicyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("symoperate", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Loads a startup policy. `grantNames == nil` means no flag was supplied;
    /// an empty array means `--grant` was supplied with no permissions.
    public static func load(grantNames: [String]?, policyURL: URL? = nil) throws -> ActionPolicy {
        let permissions: PermissionFlags
        if let grantNames {
            permissions = try parseGrantNames(grantNames)
        } else {
            permissions = try loadFilePermissions(from: policyURL ?? defaultPolicyURL)
        }
        return ActionPolicy(
            grantedPermissions: permissions,
            startupGrantedPermissions: permissions
        )
    }

    /// Parses canonical permission names, rejecting typos rather than silently
    /// starting with a broader grant than the operator requested.
    public static func parseGrantNames(_ names: [String]) throws -> PermissionFlags {
        var permissions = PermissionFlags()
        for name in names {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, let flag = PermissionFlags.flag(named: normalized) else {
                throw AutomationError.invalidArgument("Unknown grant permission '\(name)'.")
            }
            permissions.insert(flag)
        }
        return permissions
    }

    private static func loadFilePermissions(from url: URL) throws -> PermissionFlags {
        guard FileManager.default.fileExists(atPath: url.path) else { return .all }
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let names = permissionNames(in: json) else {
                throw AutomationError.invalidArgument("Startup policy must contain a 'grant' or 'granted_permissions' array.")
            }
            return try parseGrantNames(names)
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError.invalidArgument("Unable to read startup policy at \(url.path): \(error.localizedDescription)")
        }
    }

    private static func permissionNames(in json: Any) -> [String]? {
        if let names = json as? [String] { return names }
        guard let object = json as? [String: Any] else { return nil }
        for key in ["grant", "grants", "granted_permissions", "grantedPermissions"] {
            if let names = object[key] as? [String] { return names }
        }
        if let nested = object["policy"] {
            return permissionNames(in: nested)
        }
        return nil
    }
}

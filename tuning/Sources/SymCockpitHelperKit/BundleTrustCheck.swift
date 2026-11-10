import Foundation

/// Refuses to register the root helper out of a bundle somebody else could
/// rewrite (issue #405).
///
/// The registered daemon runs as root from `Contents/Library/LaunchServices`
/// inside `Symaira Cockpit.app`. An app dragged into `/Applications` is owned
/// by the installing user, so that user's malware could swap the helper for a
/// binary signed with another Developer ID. The pinned-team check
/// (``EmbeddedTeamIdentifier``) only stops such a swapped helper from pairing
/// with the app over XPC; it does not stop it from running as root. This
/// check additionally refuses while the bundle, the helper executable or any
/// directory between them is writable by anyone but its owner (group- or
/// other-writable), or is owned by somebody other than the current user or
/// root, or is a symlink.
///
/// It does *not* make a user-owned bundle safe against the owner's own
/// processes: malware running as that user can modify it, and a modified
/// helper would run as root once registered. macOS App Management protection
/// is the guard; a root-owned install closes the gap. See
/// the README and `tuning/docs/hardware-matrix.md`.
public enum BundleTrustCheck {
    public struct Stat: Sendable, Equatable {
        public var mode: UInt16
        public var owner: UInt32
        public var isSymlink: Bool
        public init(mode: UInt16, owner: UInt32, isSymlink: Bool = false) {
            self.mode = mode; self.owner = owner; self.isSymlink = isSymlink
        }
    }

    public static func lstat(_ url: URL) -> Stat? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        return Stat(
            mode: UInt16(info.st_mode & 0o7777), owner: info.st_uid,
            isSymlink: (info.st_mode & S_IFMT) == S_IFLNK
        )
    }

    /// A one-line reason to refuse, or nil when the bundle may be registered.
    ///
    /// Every path component from the bundle root down to the helper executable
    /// (`Contents`, `Contents/Library`, `Contents/Library/LaunchServices`, the
    /// helper) gets the same test as the bundle root: a writable directory
    /// around a well-protected helper would still let another user rename and
    /// replace it. A helper outside the bundle is refused.
    public static func problem(
        appBundle: URL,
        helperExecutable: URL,
        currentUser: UInt32 = getuid(),
        stat lookup: (URL) -> Stat? = BundleTrustCheck.lstat
    ) -> String? {
        let root = appBundle.standardizedFileURL
        let rootParts = root.pathComponents
        let helperParts = helperExecutable.standardizedFileURL.pathComponents
        guard helperParts.count > rootParts.count,
              Array(helperParts.prefix(rootParts.count)) == rootParts
        else {
            return "The fan helper is not inside the app bundle (\(helperExecutable.path)); not registering the privileged helper."
        }
        var chain: [(String, URL)] = [("The app bundle", root)]
        var current = root
        for (index, part) in helperParts.dropFirst(rootParts.count).enumerated() {
            current = current.appendingPathComponent(part)
            let isHelper = index == helperParts.count - rootParts.count - 1
            chain.append((isHelper ? "The fan helper" : "The bundle directory", current))
        }
        for (label, url) in chain {
            guard let info = lookup(url) else {
                return "\(label) cannot be inspected (\(url.path)); not registering the privileged helper."
            }
            if info.isSymlink {
                return "\(label) is a symbolic link (\(url.path)); not registering the privileged helper."
            }
            if info.mode & 0o022 != 0 {
                return "\(label) is writable by other users (\(url.path)); not registering the privileged helper. Remove group/other write access first."
            }
            if info.owner != currentUser && info.owner != 0 {
                return "\(label) is owned by another user (\(url.path)); not registering the privileged helper."
            }
        }
        return nil
    }
}

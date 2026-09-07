import Foundation

/// Helpers for restoring user ownership and enforcing posix permissions
/// (0700 dir, 0600 file) on state this process writes while running as root.
///
/// Ownership used to be resolved only from `SUDO_UID`/`SUDO_GID`/`SUDO_USER`.
/// That covers `sudo symcockpit …` from a terminal, but not the GUI, which
/// elevates through `osascript`'s `do shell script … with administrator
/// privileges` and sets none of those variables. On that path the chown was a
/// no-op, so the root child left root-owned 0600 files in the user's data
/// directory and every later unprivileged run failed to write history or a
/// restore record.
///
/// Ownership is therefore taken from the directory the state lives in — which
/// the user already owns — and only falls back to the sudo environment.
public enum StateFilePermissions {
    /// Resolves real user ID and group ID if running under `sudo` (euid == 0).
    public static var sudoUidGid: (uid_t, gid_t)? {
        guard geteuid() == 0 else { return nil }
        let env = ProcessInfo.processInfo.environment
        if let uidStr = env["SUDO_UID"], let uid = uid_t(uidStr),
           let gidStr = env["SUDO_GID"], let gid = gid_t(gidStr) {
            return (uid, gid)
        }
        if let sudoUser = env["SUDO_USER"], let pwd = getpwnam(sudoUser) {
            return (pwd.pointee.pw_uid, pwd.pointee.pw_gid)
        }
        return nil
    }

    /// Ownership to restore for state written under `location`.
    ///
    /// Only meaningful while running as root. The nearest existing directory at
    /// or above `location` that is not owned by root identifies the human whose
    /// data directory this is, which works for both elevation paths. The sudo
    /// environment is the fallback for the case where every ancestor is
    /// root-owned.
    public static func ownershipToRestore(
        for location: URL,
        attributesOfPath: (String) -> (uid_t, gid_t)? = Self.ownerOfPath,
        isRoot: () -> Bool = Self.isEffectivelyRoot,
        sudoOwnership: (uid_t, gid_t)?? = nil
    ) -> (uid_t, gid_t)? {
        guard isRoot() else { return nil }
        var current = location.standardized
        while true {
            if let (uid, gid) = attributesOfPath(current.path), uid != 0 {
                return (uid, gid)
            }
            let parent = current.deletingLastPathComponent().standardized
            if parent.path == current.path { break }
            current = parent
        }
        return sudoOwnership ?? sudoUidGid
    }

    public static func isEffectivelyRoot() -> Bool { geteuid() == 0 }

    public static func ownerOfPath(_ path: String) -> (uid_t, gid_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_uid, info.st_gid)
    }

    /// Ensure directory exists with 0700 permissions, owned by the user whose
    /// data directory it is rather than by root.
    public static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        // Resolve ownership before creating, so a directory this call creates
        // cannot be mistaken for evidence that root is the rightful owner.
        let owner = ownershipToRestore(for: dir)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if let (uid, gid) = owner {
            chown(dir.path, uid, gid)
        }
    }

    /// Apply 0600 permissions and restore user ownership to a file.
    public static func applyFilePermissions(at file: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let (uid, gid) = ownershipToRestore(for: file.deletingLastPathComponent()) {
            chown(file.path, uid, gid)
        }
    }
}

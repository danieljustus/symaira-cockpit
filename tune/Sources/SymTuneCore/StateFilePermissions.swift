import Foundation

/// Helpers for resolving sudo user/group ownership and enforcing posix permissions (0700 dir, 0600 file).
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

    /// Ensure directory exists with 0700 permissions and proper ownership under sudo.
    public static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if let (uid, gid) = sudoUidGid {
            chown(dir.path, uid, gid)
        }
    }

    /// Apply 0600 permissions and sudo ownership to a file.
    public static func applyFilePermissions(at file: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let (uid, gid) = sudoUidGid {
            chown(file.path, uid, gid)
        }
    }
}

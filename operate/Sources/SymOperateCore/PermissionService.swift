import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public struct PermissionService: PermissionServiceProtocol {
    public init() {}

    public func status() -> PermissionSnapshot {
        let pid = getpid()
        let ppid = getppid()
        let execPath = executablePath(for: pid) ?? ProcessInfo.processInfo.arguments.first ?? "unknown"
        let parentName = processName(for: ppid)

        return PermissionSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            source: PermissionSource(
                pid: pid,
                ppid: ppid,
                executablePath: execPath,
                launchingProcessName: parentName,
                note: "These booleans describe the TCC grants held by the process identified above. On macOS, TCC permissions (Accessibility, Screen Recording) are per-process — granting them to the launching app (e.g., Terminal, Cursor) does NOT make them available to the MCP host that launched symoperate. Grant permissions from the process that will actually be using symoperate's MCP server."
            )
        )
    }

    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Process info helpers

    /// Maximum buffer size for `proc_pidpath` as defined in `<libproc.h>`.
    private static let procPathBufferSize: UInt32 = 4096

    /// Returns the resolved absolute executable path for the given PID, or nil on failure.
    private func executablePath(for pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(Self.procPathBufferSize))
        defer { buffer.deallocate() }
        let written = proc_pidpath(pid, buffer, Self.procPathBufferSize)
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Returns a human-readable process name for the given PID, or nil if unobtainable.
    /// On macOS this uses `proc_name()` from libproc, which works for both GUI apps and
    /// command-line processes.
    private func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let written = proc_name(pid, &buffer, UInt32(MAXCOMLEN))
        guard written > 0 else { return nil }
        let name = buffer.withUnsafeBytes { rawBuf in
            String(bytes: rawBuf.prefix(Int(MAXCOMLEN)), encoding: .utf8)
        }
        .map { $0.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces) } ?? nil
        return name?.isEmpty == false ? name : nil
    }
}

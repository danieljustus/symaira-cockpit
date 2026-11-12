import Foundation
import SymCockpitHistory

/// Whether a standalone `fan governor` process (the administrator-prompt
/// path, `symcockpit [tune] fan governor`) is running. Shared by the GUI's
/// status probe and the privileged helper, which must not hand the fans back
/// to the firmware while that process still owns them.
public enum FanGovernorProcessProbe {
    /// `pgrep -f` matches both the direct and the deprecated `tune` spelling.
    /// A probe that cannot run answers `false`.
    public static func isRunning() -> Bool {
        guard let result = try? BoundedProcessRunner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "fan governor"],
            timeoutSeconds: 5
        ) else { return false }
        return result.terminationStatus == 0
    }
}

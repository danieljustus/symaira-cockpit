import Foundation

/// Fixed identities and timings shared by the app and the privileged fan
/// helper (issue #405).
///
/// The helper identity is the grandfathered `com.symaira.symtune-helper`
/// (see the root AGENTS.md): it is the launchd label, the Mach service the
/// XPC listener registers, the code-signing identifier of the helper
/// executable and the stem of its launchd plist. Renaming any of them would
/// orphan an already-approved helper registration.
public enum FanHelperConstants {
    /// Launchd label, Mach service name and code-signing identifier.
    public static let helperIdentifier = "com.symaira.symtune-helper"

    /// `SMAppService.daemon(plistName:)` argument; the plist sits in the
    /// app's `Contents/Library/LaunchDaemons/`.
    public static let launchdPlistName = "com.symaira.symtune-helper.plist"

    /// Bundle identifier (and code-signing identifier) of `Symaira Cockpit.app`.
    public static let appIdentifier = "com.symaira.cockpit"

    /// Path of the helper executable relative to the app bundle. This is also
    /// the `BundleProgram` value in the launchd plist.
    public static let helperBundleProgram =
        "Contents/Library/LaunchServices/com.symaira.symtune-helper"

    /// How often the app pings the helper while it governs.
    public static let heartbeatInterval: TimeInterval = 2

    /// The helper hands the fans back to the firmware when no heartbeat
    /// arrived for *more than* this long. Three missed pings of slack.
    public static let heartbeatTimeout: TimeInterval = 7

    /// How often the helper checks the heartbeat. Bounds the overshoot of
    /// ``heartbeatTimeout``.
    public static let watchdogCheckInterval: TimeInterval = 1

    /// Granularity of the governor's interruptible sleep: how quickly a stop
    /// request reaches a governor that is between two ticks.
    public static let sleepSlice: TimeInterval = 0.2

    /// Upper bound for the helper to restore the fans on SIGTERM before it
    /// exits regardless.
    public static let terminationGrace: TimeInterval = 5
}

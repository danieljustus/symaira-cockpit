import Foundation

/// Code-signing requirement strings for the two directions of the helper's
/// XPC connection. Both are anchored on Apple's Developer ID chain and pinned
/// to *one* team identifier, which is derived from the running binary's own
/// signature (never hardcoded):
///
/// - the helper accepts only `Symaira Cockpit.app` (``appRequirement(teamID:)``);
/// - the app accepts only the helper (``helperRequirement(teamID:)``).
///
/// Peers that carry a hardened-runtime escape entitlement are refused as
/// well, so a re-signed copy that lifts library validation or allows
/// DYLD injection cannot talk to a root process.
public enum CodeSigningRequirements {
    /// Entitlements that defeat the hardened runtime.
    public static let forbiddenEntitlements = [
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-jit",
    ]

    /// Apple team identifiers are ten upper-case alphanumerics. Anything
    /// else is rejected before it can reach a requirement string, which closes
    /// the door on requirement-language injection through a forged value.
    public static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
        }
    }

    /// What the helper requires of its client.
    public static func appRequirement(teamID: String) -> String? {
        requirement(identifier: FanHelperConstants.appIdentifier, teamID: teamID)
    }

    /// What the app requires of the helper.
    public static func helperRequirement(teamID: String) -> String? {
        requirement(identifier: FanHelperConstants.helperIdentifier, teamID: teamID)
    }

    private static func requirement(identifier: String, teamID: String) -> String? {
        guard isValidTeamIdentifier(teamID) else { return nil }
        let denied = forbiddenEntitlements
            .map { "!entitlement[\"\($0)\"] exists" }
            .joined(separator: " and ")
        return "anchor apple generic"
            + " and identifier \"\(identifier)\""
            // Developer ID Application leaf and the Developer ID CA: rules
            // out Mac App Store, development and plain Apple-issued certs.
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and \(denied)"
    }
}

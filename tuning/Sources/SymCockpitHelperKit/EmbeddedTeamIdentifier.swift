import Foundation

/// The Apple Developer Team identifier this build is *expected* to be signed
/// with, baked in at build time (issue #405).
///
/// ``FanHelperConnectionPolicy`` and ``FanHelperClient/detectSigning(embeddedTeamID:)``
/// require the team read from the running binary's own signature to equal
/// this constant. Without it, "any Developer ID with the same team as my own
/// signature" would be the only trust root, and a helper binary swapped for
/// one signed by a different Developer ID would still pair with itself.
///
/// The committed value is `nil`: such a build (every local, CI and debug
/// build) never registers and never serves the helper. `scripts/build-app.sh`
/// rewrites the literal below from `EXPECTED_TEAM_ID` for a release build and
/// restores the file afterwards; `release.yml` derives that value from the
/// Developer ID certificate it signs with and later checks the signed bundle
/// against it. Never hardcode a guessed team identifier here.
public enum EmbeddedTeamIdentifier {
    // build-app.sh replaces the next line; keep the marker comment intact.
    public static let value: String? = nil // EMBEDDED-TEAM-ID
}

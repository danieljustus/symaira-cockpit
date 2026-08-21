import Foundation

/// Single source of truth for the tool version. Kept in sync with the git tag
/// on release (`v<version>`); release builds override this value via the
/// `SYMTUNE_VERSION` environment variable so the binary always reports the tag
/// it was built from.
public enum TuneVersion: Sendable {
    public static let current = "0.9.3"
}

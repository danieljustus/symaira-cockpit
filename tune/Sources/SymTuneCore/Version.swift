import Foundation

/// Single source of truth for the embedded Tune component baseline.
/// This identity is independent of the Cockpit release tag and is read
/// directly by component version reports, without an environment override.
public enum TuneVersion: Sendable {
    public static let current = "0.10.0"
}

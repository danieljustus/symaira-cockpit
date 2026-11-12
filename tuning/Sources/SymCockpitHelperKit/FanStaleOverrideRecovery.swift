import Foundation

/// Hands forced fans back to the firmware when nobody governs them any more.
///
/// The helper's own governor restores on every orderly exit, but a helper
/// that dies mid-run (SIGKILL, SIGTRAP, jetsam) cannot, and the fans then stay
/// at the last forced target. A fresh helper never governs at launch, so any
/// override it finds is stale by definition, unless the standalone
/// `fan governor` process holds it (issue #414).
public enum FanStaleOverrideRecovery {
    public enum Outcome: Equatable, Sendable {
        case nothingForced
        case legacyGovernorRunning
        case restored
        case failed(String)
    }

    /// Reads the override first (cheap SMC reads); the process probe runs
    /// only when something is forced.
    public static func run(
        hasOverride: () -> Bool,
        legacyGovernorRunning: () -> Bool,
        restore: () throws -> Void
    ) -> Outcome {
        guard hasOverride() else { return .nothingForced }
        guard !legacyGovernorRunning() else { return .legacyGovernorRunning }
        do {
            try restore()
            return .restored
        } catch {
            return .failed("\(error)")
        }
    }
}

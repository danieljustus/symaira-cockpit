import Foundation

/// Decides when the helper may exit by itself.
///
/// The helper is a launchd on-demand daemon (Mach service, no `KeepAlive`), so
/// it never exited before: after `brew upgrade` replaced the app bundle the
/// *old* process kept serving the new app until reboot. Exiting when idle lets
/// launchd start the current binary on the next Mach lookup, so the next
/// upgrade swaps the helper without any user action.
///
/// "Idle" means all of: no client connection, no governor run (the governor
/// restores the fans before it counts as finished, so an idle helper has
/// already handed them back), continuously for ``grace``. The decision is pure
/// (``shouldExit(isGoverning:hasConnection:idleFor:grace:)``) so it is
/// testable without a daemon; the monitor only feeds it the clock.
public final class FanHelperIdleMonitor: @unchecked Sendable {
    /// The pure rule: exit only when idle for at least `grace`.
    public static func shouldExit(
        isGoverning: Bool, hasConnection: Bool, idleFor: TimeInterval, grace: TimeInterval
    ) -> Bool {
        !isGoverning && !hasConnection && idleFor >= grace
    }

    private let grace: TimeInterval
    private let isGoverning: @Sendable () -> Bool
    private let hasConnection: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var idleSince: Date?

    /// The idle clock starts at creation: a helper that nobody connects to
    /// within the grace period (launchd started it for a lookup that never
    /// became a connection) exits as well.
    public init(
        grace: TimeInterval = FanHelperConstants.idleExitGrace,
        isGoverning: @escaping @Sendable () -> Bool,
        hasConnection: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.grace = grace
        self.isGoverning = isGoverning
        self.hasConnection = hasConnection
        self.now = now
        self.idleSince = now()
    }

    /// One evaluation. Returns true when the helper should exit now. Any
    /// connection or governor resets the idle clock.
    public func tick() -> Bool {
        let governing = isGoverning()
        let connected = hasConnection()
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        if governing || connected {
            idleSince = nil
            return false
        }
        let since = idleSince ?? current
        idleSince = since
        return Self.shouldExit(
            isGoverning: governing, hasConnection: connected,
            idleFor: current.timeIntervalSince(since), grace: grace
        )
    }
}

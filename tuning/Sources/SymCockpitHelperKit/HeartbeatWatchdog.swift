import Foundation

/// Dead-man timer for the app's heartbeat. Pure bookkeeping around an
/// injected monotonic clock so the timing is testable without sleeping.
public final class HeartbeatWatchdog: @unchecked Sendable {
    public static let monotonicClock: @Sendable () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }

    public let timeout: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var lastBeat: TimeInterval

    public init(
        timeout: TimeInterval = FanHelperConstants.heartbeatTimeout,
        clock: @escaping @Sendable () -> TimeInterval = HeartbeatWatchdog.monotonicClock
    ) {
        self.timeout = timeout
        self.clock = clock
        self.lastBeat = clock()
    }

    /// Records a heartbeat (also used to arm the watchdog when a run starts).
    public func beat() {
        let now = clock()
        lock.lock()
        lastBeat = now
        lock.unlock()
    }

    public var secondsSinceLastBeat: TimeInterval {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        return now - lastBeat
    }

    /// True once *more than* `timeout` seconds passed without a beat.
    public var isExpired: Bool { secondsSinceLastBeat > timeout }
}

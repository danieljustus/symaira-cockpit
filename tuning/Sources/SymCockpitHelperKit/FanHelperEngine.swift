import Foundation
import SymCockpitCore

/// Owns the governor run inside the helper and enforces the dead-man rules.
///
/// The engine does not fork the governor: it runs the existing
/// `FanGovernor` loop (with its bounded failure policy) through an injected
/// ``GovernorRunner``. Whatever ends a run — the app's `stop`, a missing
/// heartbeat, an invalidated connection, SIGTERM, or the governor giving up
/// on its own — makes the loop unwind through the governor's own `defer`,
/// which puts every fan back to the state it found. The engine never writes
/// the SMC itself.
public final class FanHelperEngine: @unchecked Sendable {
    /// Why a run ended.
    public enum StopReason: String, Sendable, Equatable {
        case requested
        case heartbeatTimeout
        case connectionInvalidated
        case terminated
        case profileSystem
        /// The governor returned or threw by itself.
        case governorFinished
    }

    public struct Snapshot: Sendable, Equatable {
        public var isGoverning: Bool
        public var profile: FanProfile
        public var lastStopReason: StopReason?
        public var failure: String?
    }

    /// Runs the governor loop. `sleep` is interruptible and must be handed to
    /// the `FanGovernor` so a stop takes effect between ticks.
    public typealias GovernorRunner = @Sendable (
        _ profileProvider: @Sendable () -> FanProfile,
        _ shouldContinue: @Sendable () -> Bool,
        _ sleep: @escaping @Sendable (TimeInterval) -> Void
    ) throws -> Void

    private final class Run: @unchecked Sendable {
        let lock = NSLock()
        private var _profile: FanProfile
        private var _stopped = false
        private var _finished = false

        init(profile: FanProfile) { _profile = profile }

        var profile: FanProfile {
            get { lock.lock(); defer { lock.unlock() }; return _profile }
            set { lock.lock(); _profile = newValue; lock.unlock() }
        }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
        func stop() { lock.lock(); _stopped = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        func markFinished() { lock.lock(); _finished = true; lock.unlock() }
    }

    private let watchdog: HeartbeatWatchdog
    private let runner: GovernorRunner
    private let sleepSlice: TimeInterval
    private let lock = NSLock()
    private var run: Run?
    private var lastStopReason: StopReason?
    private var failure: String?
    private var timer: DispatchSourceTimer?

    public init(
        watchdog: HeartbeatWatchdog = HeartbeatWatchdog(),
        sleepSlice: TimeInterval = FanHelperConstants.sleepSlice,
        runner: @escaping GovernorRunner
    ) {
        self.watchdog = watchdog
        self.sleepSlice = sleepSlice
        self.runner = runner
    }

    // MARK: - Commands

    /// Starts the governor on `profile`, or retargets a running one.
    /// `.system` is a stop: the helper never "governs" the firmware curve.
    public func start(profile: FanProfile) {
        guard profile != .system else {
            stop(reason: .profileSystem)
            return
        }
        lock.lock()
        if let run, !run.isStopped, !run.isFinished {
            run.profile = profile
            lock.unlock()
            watchdog.beat()
            return
        }
        let newRun = Run(profile: profile)
        run = newRun
        failure = nil
        lastStopReason = nil
        lock.unlock()

        watchdog.beat()
        let slice = sleepSlice
        let runner = self.runner
        let thread = Thread { [weak self] in
            var error: Error?
            do {
                try runner(
                    { newRun.profile },
                    { !newRun.isStopped },
                    { Self.interruptibleSleep($0, slice: slice, run: newRun) }
                )
            } catch let thrown {
                error = thrown
            }
            self?.finished(newRun, error: error)
        }
        thread.name = "symaira.fan-helper.governor"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Asks the current run to stop. Returns immediately; the governor
    /// restores the fans on its way out (see ``waitUntilIdle(timeout:)``).
    public func stop(reason: StopReason) {
        lock.lock()
        guard let run, !run.isStopped, !run.isFinished else {
            lock.unlock()
            return
        }
        run.stop()
        lastStopReason = reason
        lock.unlock()
    }

    public func heartbeat() {
        watchdog.beat()
    }

    /// The XPC connection that owned the run went away: the app is gone, so
    /// nothing is left to send heartbeats.
    public func connectionInvalidated() {
        stop(reason: .connectionInvalidated)
    }

    /// One watchdog evaluation. Stops the run when no heartbeat arrived for
    /// more than the timeout. Returns whether it stopped one.
    @discardableResult
    public func watchdogTick() -> Bool {
        lock.lock()
        let active = run.map { !$0.isStopped && !$0.isFinished } ?? false
        lock.unlock()
        guard active, watchdog.isExpired else { return false }
        stop(reason: .heartbeatTimeout)
        return true
    }

    /// Runs ``watchdogTick()`` on a repeating timer. Call once in the helper.
    public func startWatchdogTimer(
        interval: TimeInterval = FanHelperConstants.watchdogCheckInterval,
        queue: DispatchQueue = DispatchQueue(label: "symaira.fan-helper.watchdog")
    ) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.watchdogTick() }
        lock.lock()
        timer?.cancel()
        timer = source
        lock.unlock()
        source.resume()
    }

    /// SIGTERM: stop the run and wait (bounded) for the restore to finish.
    public func terminate(grace: TimeInterval = FanHelperConstants.terminationGrace) {
        stop(reason: .terminated)
        _ = waitUntilIdle(timeout: grace)
    }

    // MARK: - Observation

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let active = run.map { !$0.isFinished } ?? false
        return Snapshot(
            isGoverning: active,
            profile: active ? (run?.profile ?? .system) : .system,
            lastStopReason: lastStopReason,
            failure: failure
        )
    }

    /// Blocks until no run is active (the fans are restored), or `timeout`.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !snapshot.isGoverning { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !snapshot.isGoverning
    }

    // MARK: - Internals

    private func finished(_ finishedRun: Run, error: Error?) {
        finishedRun.markFinished()
        lock.lock()
        defer { lock.unlock() }
        guard run === finishedRun else { return }
        if let error { failure = "\(error)" }
        if lastStopReason == nil { lastStopReason = .governorFinished }
    }

    private static func interruptibleSleep(_ seconds: TimeInterval, slice: TimeInterval, run: Run) {
        let deadline = Date().addingTimeInterval(seconds)
        while !run.isStopped {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            Thread.sleep(forTimeInterval: min(slice, remaining))
        }
    }
}

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
        public var coolTarget: Double?
        public var lastStopReason: StopReason?
        public var failure: String?
    }

    /// Runs the governor loop. `sleep` is interruptible and must be handed to
    /// the `FanGovernor` so a stop takes effect between ticks.
    public typealias GovernorRunner = @Sendable (
        _ selectionProvider: @Sendable () -> FanSelection,
        _ shouldContinue: @Sendable () -> Bool,
        _ sleep: @escaping @Sendable (TimeInterval) -> Void
    ) throws -> Void

    private final class Run: @unchecked Sendable {
        let lock = NSLock()
        private var _selection: FanSelection
        private var _stopped = false
        private var _finished = false
        /// Entered at creation, left when the governor has unwound (the fans
        /// are restored). A successor run waits on it before touching the SMC.
        private let unwound = DispatchGroup()

        init(selection: FanSelection) { _selection = selection; unwound.enter() }

        var selection: FanSelection {
            get { lock.lock(); defer { lock.unlock() }; return _selection }
            set { lock.lock(); _selection = newValue; lock.unlock() }
        }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
        func stop() { lock.lock(); _stopped = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        func markFinished() {
            lock.lock()
            let first = !_finished
            _finished = true
            lock.unlock()
            if first { unwound.leave() }
        }
        /// Blocks until this run has fully unwound.
        func waitUntilUnwound() { unwound.wait() }
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
    ///
    /// `coolTarget` is clamped to ``FanCoolTarget/range`` here as well (a
    /// non-finite one is dropped), and only the Cool position uses it.
    public func start(profile: FanProfile, coolTarget: Double? = nil) {
        guard profile != .system else {
            stop(reason: .profileSystem)
            return
        }
        let selection = FanSelection(profile: profile, coolTargetCelsius: coolTarget)
        lock.lock()
        if let run, !run.isStopped, !run.isFinished {
            run.selection = selection
            lock.unlock()
            watchdog.beat()
            return
        }
        // A stopped run that is still restoring the fans must finish first:
        // two governors would write the SMC concurrently, and the new one
        // would capture the half-restored state as the "original" to hand
        // back (leaving the fans pinned when it ends).
        let previous = run
        let newRun = Run(selection: selection)
        run = newRun
        failure = nil
        lastStopReason = nil
        lock.unlock()

        watchdog.beat()
        let slice = sleepSlice
        let runner = self.runner
        let thread = Thread { [weak self] in
            previous?.waitUntilUnwound()
            var error: Error?
            do {
                // Stopped while still queued behind the previous run: never
                // start, so nothing is captured or overridden.
                if !newRun.isStopped {
                    try runner(
                        { newRun.selection },
                        { !newRun.isStopped },
                        { Self.interruptibleSleep($0, slice: slice, run: newRun) }
                    )
                }
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
    /// Returns whether the restore completed within `grace`.
    @discardableResult
    public func terminate(grace: TimeInterval = FanHelperConstants.terminationGrace) -> Bool {
        stop(reason: .terminated)
        return waitUntilIdle(timeout: grace)
    }

    // MARK: - Observation

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let active = run.map { !$0.isFinished } ?? false
        return Snapshot(
            isGoverning: active,
            profile: active ? (run?.selection.profile ?? .system) : .system,
            coolTarget: active ? run?.selection.effectiveCoolTarget : nil,
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

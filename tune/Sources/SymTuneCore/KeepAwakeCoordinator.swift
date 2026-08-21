import Foundation

/// Coordinates at most one keep-awake session backed by a `PowerAssertionSource`.
/// Thread-safe: uses an internal lock.  No IOKit coupling — the source is
/// injectable so tests can verify behaviour without creating real assertions.
public final class KeepAwakeCoordinator: @unchecked Sendable {
    private let source: any PowerAssertionSource
    private let lock = NSLock()

    private var token: KeepAwakeToken?
    private var session: KeepAwakeSession?
    private var expiryTimer: DispatchSourceTimer?

    public init(source: any PowerAssertionSource = HardwarePowerAssertionSource()) {
        self.source = source
    }

    deinit {
        end()
    }

    // MARK: - Public API

    /// Start a keep-awake session.  If a session is already active, the call
    /// is a no-op and the current session is returned unchanged.
    ///
    /// - Parameters:
    ///   - duration: If non-nil the session expires after this many seconds.
    ///   - preventDisplaySleep: Prevents display sleep when `true`.
    ///   - reason: Human-readable reason (passed to the IOKit assertion).
    /// - Returns: The current (possibly new) session state.
    @discardableResult
    public func begin(
        duration: TimeInterval?,
        preventDisplaySleep: Bool,
        reason: String
    ) throws -> KeepAwakeSession {
        lock.lock()
        defer { lock.unlock() }

        // Already active — return current session unchanged.
        if let existing = session, existing.active {
            return existing
        }

        let tok = try source.create(
            type: preventDisplaySleep ? .preventDisplaySleep : .preventSystemSleep,
            reason: reason
        )
        token = KeepAwakeToken(id: IOPMAssertionID(tok))

        let startedAt = Date()
        let expiresAt: Date? = duration.map { startedAt.addingTimeInterval($0) }
        let sess = KeepAwakeSession(
            active: true,
            preventDisplaySleep: preventDisplaySleep,
            startedAt: startedAt,
            expiresAt: expiresAt,
            reason: reason
        )
        session = sess

        // Schedule expiry timer when a duration is given.
        if let duration {
            scheduleExpiry(after: duration)
        }

        return sess
    }

    /// End the current session if one is active.  Idempotent — calling
    /// `end()` on an already-ended session is safe.
    public func end() {
        lock.lock()
        defer { lock.unlock() }

        cancelExpiryTimer()

        guard let tok = token else { return }
        source.release(UInt32(tok.id))
        token = nil
        session = KeepAwakeSession.inactive
    }

    /// Return a snapshot of the current session state.  Never returns `nil` —
    /// an inactive session is represented by `KeepAwakeSession.inactive`.
    public func status() -> KeepAwakeSession {
        lock.lock()
        defer { lock.unlock() }
        return session ?? KeepAwakeSession.inactive
    }

    // MARK: - Internals

    private func scheduleExpiry(after duration: TimeInterval) {
        cancelExpiryTimer()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .default))
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            self?.onExpiry()
        }
        timer.resume()
        expiryTimer = timer
    }

    private func cancelExpiryTimer() {
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    private func onExpiry() {
        lock.lock()
        if let sess = session, sess.active {
            if let tok = token {
                source.release(UInt32(tok.id))
            }
            token = nil
            session = KeepAwakeSession.inactive
            expiryTimer = nil
        }
        lock.unlock()
    }
}

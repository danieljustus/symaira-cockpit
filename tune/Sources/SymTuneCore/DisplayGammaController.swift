@preconcurrency import AppKit

/// Single owner of every display's gamma table.
///
/// Two features write that table — colour warmth and extended ("beyond 100%")
/// brightness. Whoever wrote last used to win, and warmth additionally rebuilt
/// the table from scratch instead of modifying the display's own calibration,
/// so a neutral setting still changed how the screen looked. This controller
/// keeps the captured base ramp per display and re-composes it from *both*
/// inputs on every change (see ``GammaComposition``).
///
/// When both inputs return to neutral the display is handed back to ColorSync
/// and the captured ramp is dropped, so "normal" means the display exactly as
/// the system drives it — nothing left behind.
public final class DisplayGammaController: @unchecked Sendable {

    /// Shared instance. Gamma is a global, per-display hardware resource: two
    /// controllers would fight over the same table.
    public static let shared = DisplayGammaController()

    private struct DisplayState {
        var base: GammaRamp
        var warmth: Float = 0
        var boost: Float = 1.0
    }

    private let io: any GammaIO
    private let sampleCount: Int
    private let lock = NSLock()
    private var states: [CGDirectDisplayID: DisplayState] = [:]

    public init(io: any GammaIO = CoreGraphicsGammaIO(), sampleCount: Int = 256) {
        self.io = io
        self.sampleCount = sampleCount
    }

    // MARK: - Queries

    /// Applied warmth for a display (`0` when untouched).
    public func warmth(for displayID: CGDirectDisplayID) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return states[displayID]?.warmth ?? 0
    }

    /// Applied brightness boost for a display (`1.0` when untouched).
    public func boost(for displayID: CGDirectDisplayID) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return states[displayID]?.boost ?? 1.0
    }

    /// Whether any display currently has a composed table applied.
    public var hasOverrides: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !states.isEmpty
    }

    // MARK: - Mutations

    /// Set the warmth shift for `displayID`, keeping any active boost.
    public func setWarmth(_ warmth: Float, displayID: CGDirectDisplayID) throws {
        try update(displayID: displayID) { $0.warmth = min(max(warmth, 0), 1) }
    }

    /// Set the extended-brightness boost for `displayID`, keeping any warmth.
    ///
    /// - Parameter boost: `1.0` removes the boost. Callers must have already
    ///   clamped to the headroom the display actually granted; writing a boost
    ///   the panel cannot back would clip instead of brighten.
    public func setBoost(_ boost: Float, displayID: CGDirectDisplayID) throws {
        try update(displayID: displayID) { $0.boost = max(boost, 1.0) }
    }

    /// Drop every override on `displayID` and hand it back to ColorSync.
    public func reset(displayID: CGDirectDisplayID) {
        lock.lock()
        let had = states.removeValue(forKey: displayID) != nil
        let remaining = states
        lock.unlock()
        guard had else { return }

        // `CGDisplayRestoreColorSyncSettings` is all-displays; re-apply the
        // others so resetting one display cannot silently clear its neighbour.
        io.restoreSystemRamps()
        for (id, state) in remaining {
            if let ramp = GammaComposition.compose(base: state.base, warmth: state.warmth, boost: state.boost) {
                _ = io.writeRamp(ramp, displayID: id)
            }
        }
    }

    /// Drop every override on every display.
    public func resetAll() {
        lock.lock()
        let had = !states.isEmpty
        states.removeAll()
        lock.unlock()
        guard had else { return }
        io.restoreSystemRamps()
    }

    /// Re-write the composed tables from the cached state.
    ///
    /// macOS resets the gamma table on display sleep/wake and on display
    /// reconfiguration, which silently drops the boost. The app calls this on
    /// wake so the user's setting survives instead of quietly reverting.
    public func reassert() {
        lock.lock()
        let snapshot = states
        lock.unlock()
        for (id, state) in snapshot {
            guard let ramp = GammaComposition.compose(
                base: state.base,
                warmth: state.warmth,
                boost: state.boost
            ) else { continue }
            _ = io.writeRamp(ramp, displayID: id)
        }
    }

    // MARK: - Private

    private func update(
        displayID: CGDirectDisplayID,
        _ mutate: (inout DisplayState) -> Void
    ) throws {
        lock.lock()
        var state: DisplayState
        if let existing = states[displayID] {
            state = existing
        } else {
            // Capture the display's own table once, before anything is applied.
            guard let base = io.readRamp(displayID: displayID, sampleCount: sampleCount) else {
                lock.unlock()
                throw TuneError.failed("Could not read the gamma table for display \(displayID).")
            }
            state = DisplayState(base: base)
        }
        mutate(&state)

        if GammaComposition.isNeutral(warmth: state.warmth, boost: state.boost) {
            states.removeValue(forKey: displayID)
            let remaining = states
            lock.unlock()
            io.restoreSystemRamps()
            for (id, other) in remaining {
                if let ramp = GammaComposition.compose(base: other.base, warmth: other.warmth, boost: other.boost) {
                    _ = io.writeRamp(ramp, displayID: id)
                }
            }
            return
        }

        guard let ramp = GammaComposition.compose(
            base: state.base,
            warmth: state.warmth,
            boost: state.boost
        ) else {
            lock.unlock()
            throw TuneError.failed("Could not compose a gamma table for display \(displayID).")
        }
        let previous = states[displayID]
        states[displayID] = state
        lock.unlock()

        guard io.writeRamp(ramp, displayID: displayID) else {
            // Roll the recorded state back to what the hardware still has.
            // Keeping the optimistic value would make `warmth(for:)`/`boost(for:)`
            // — and the readout built on them — report an override that was
            // never applied.
            lock.lock()
            if let previous {
                states[displayID] = previous
            } else {
                states.removeValue(forKey: displayID)
            }
            lock.unlock()
            throw TuneError.failed("CGSetDisplayTransferByTable failed for display \(displayID).")
        }
    }
}

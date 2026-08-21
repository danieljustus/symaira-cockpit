import Foundation

/// Thread-safe bookkeeping for the charge limit this process applied most
/// recently. Status reporting cross-checks the tracked percent against the
/// live SMC inhibit state (see `TuneController.activeChargeLimit()`), so the
/// tracked value alone is never reported as enforced — on Apple Silicon the
/// inhibit bit is volatile and resets on sleep.
final class ChargeLimitState: @unchecked Sendable {
    private let lock = NSLock()
    private var trackedPercent: Int?

    /// The configured limit percent, or `nil` when no limit is set.
    var percent: Int? {
        lock.lock()
        defer { lock.unlock() }
        return trackedPercent
    }

    /// Record a newly applied limit.
    func set(_ percent: Int) {
        lock.lock()
        trackedPercent = percent
        lock.unlock()
    }

    /// Forget the limit (after a clear or a full restore).
    func clear() {
        lock.lock()
        trackedPercent = nil
        lock.unlock()
    }
}

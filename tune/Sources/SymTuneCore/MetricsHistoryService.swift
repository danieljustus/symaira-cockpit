import Foundation

/// Aggregated statistics for a single metric over its current sample window.
public struct MetricStats: Codable, Sendable, Equatable {
    public let current: Double
    public let min: Double
    public let max: Double

    public init(current: Double, min: Double, max: Double) {
        self.current = current
        self.min = min
        self.max = max
    }
}

/// A service that maintains a bounded rolling window of metric samples for
/// each enabled system metric, backed by ``MetricsRingBuffer`` instances.
///
/// ## Lifecycle
/// Call ``record(_:)`` periodically with the latest ``SystemMetricsReport``
/// to feed samples into the ring buffers. Buffers are created lazily for
/// each enabled metric and dropped when a metric is disabled via
/// ``ensureBuffers(for:)``.
///
/// ## Gaps
/// When a metric becomes unavailable mid-window (e.g. CPU readings stop
/// during sleep), ``record(_:)`` inserts a gap marker so that sparkline
/// renderers break the polyline — no fabricated straight lines across the
/// missing interval.
public final class MetricsHistoryService: @unchecked Sendable {
    /// Sample capacity per metric ring buffer (memory bounded).
    public let capacity: Int

    private var buffers: [MetricIdentifier: MetricsRingBuffer] = [:]
    private let lock = NSLock()

    // MARK: - Lifecycle

    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    // MARK: - Buffer management

    /// Ensure buffers exist exactly for the given set of enabled metrics.
    /// Buffers for metrics no longer in the set are dropped immediately.
    public func ensureBuffers(for enabled: Set<MetricIdentifier>) {
        lock.lock()
        defer { lock.unlock() }
        // Drop disabled
        for key in buffers.keys where !enabled.contains(key) {
            buffers.removeValue(forKey: key)
        }
        // Create enabled
        for id in enabled {
            if buffers[id] == nil {
                buffers[id] = MetricsRingBuffer(capacity: capacity)
            }
        }
    }

    /// Drop all history for a specific metric.
    public func dropHistory(for id: MetricIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeValue(forKey: id)
    }

    /// Return the ring buffer for a metric, or `nil` if it has never been
    /// enabled since the last ``ensureBuffers(for:)`` call.
    public func buffer(for id: MetricIdentifier) -> MetricsRingBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers[id]
    }

    // MARK: - Recording

    /// Extract metric values from a ``SystemMetricsReport`` and record
    /// them into the corresponding ring buffers. Metrics that are absent
    /// from the report (or whose values are `nil`) get a gap marker.
    public func record(_ report: SystemMetricsReport, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        // CPU
        if let buf = buffers[.cpu] {
            if let util = report.cpu.totalUtilization {
                buf.recordValue(util * 100.0, timestamp: timestamp)
            } else {
                buf.recordGap(reason: "unavailable", timestamp: timestamp)
            }
        }

        // Memory
        if let buf = buffers[.memory] {
            if let used = report.memory.usedBytes {
                buf.recordValue(Double(used), timestamp: timestamp)
            } else {
                buf.recordGap(reason: "unavailable", timestamp: timestamp)
            }
        }

        // Disk
        if let buf = buffers[.disk] {
            if let d = report.disk {
                let pct = d.capacityBytes > 0
                    ? (Double(d.usedBytes) / Double(d.capacityBytes)) * 100.0
                    : 0.0
                buf.recordValue(pct, timestamp: timestamp)
            } else {
                buf.recordGap(reason: "unavailable", timestamp: timestamp)
            }
        }

        // Network
        if let buf = buffers[.network] {
            let down = report.network.aggregateBytesInPerSecond
            let up = report.network.aggregateBytesOutPerSecond
            if let d = down, let u = up {
                buf.recordValue(d + u, timestamp: timestamp)
            } else if let d = down {
                buf.recordValue(d, timestamp: timestamp)
            } else if let u = up {
                buf.recordValue(u, timestamp: timestamp)
            } else {
                buf.recordGap(reason: "unavailable", timestamp: timestamp)
            }
        }
    }

    /// Insert a sleep/wake gap marker into every active buffer.
    /// Call this when the system wakes from sleep so sparklines show a
    /// visible break instead of an interpolated line.
    public func recordWakeGap(timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        for buf in buffers.values {
            buf.recordGap(reason: "sleep", timestamp: timestamp)
        }
    }

    // MARK: - Queries

    /// Snapshot of samples for a metric, or `[]` if no buffer exists.
    public func samples(for id: MetricIdentifier) -> [MetricSample] {
        buffer(for: id)?.samples ?? []
    }

    /// Current, min, max for a metric, or `nil` if no value samples exist.
    public func stats(for id: MetricIdentifier) -> MetricStats? {
        guard let buf = buffer(for: id), let mm = buf.currentMinMax, let cur = buf.latestValue else {
            return nil
        }
        return MetricStats(current: cur, min: mm.min, max: mm.max)
    }
}

import Foundation

// MARK: - Metric Sample

/// One sample in a metric's rolling history window.
///
/// A sample with `value == nil` represents a **gap** — a sleep/wake boundary
/// or a period where the metric was unavailable. Sparkline renderers break the
/// polyline at gaps instead of interpolating a fabricated straight line.
public struct MetricSample: Codable, Sendable, Equatable {
    public let timestamp: Date
    /// `nil` marks a deliberate gap. Rendered as a break in the sparkline.
    public let value: Double?
    /// Human-readable label for the gap (e.g. "sleep", "unavailable").
    public let gapReason: String?

    public init(timestamp: Date, value: Double?, gapReason: String? = nil) {
        self.timestamp = timestamp
        self.value = value
        self.gapReason = gapReason
    }

    /// A real-valued sample.
    public static func sample(timestamp: Date = Date(), _ value: Double) -> MetricSample {
        MetricSample(timestamp: timestamp, value: value)
    }

    /// A gap marker.
    public static func gap(timestamp: Date = Date(), reason: String? = nil) -> MetricSample {
        MetricSample(timestamp: timestamp, value: nil, gapReason: reason)
    }

    /// Whether this sample is a real value (not a gap).
    public var isValue: Bool { value != nil }
}

// MARK: - Metrics Ring Buffer

/// A bounded, thread-safe ring buffer for storing a rolling window of
/// ``MetricSample`` values for one metric.
///
/// ## Capacity
/// The buffer has a fixed capacity; when full the oldest sample is evicted
/// (FIFO). Memory use stays flat over arbitrarily long runs.
///
/// ## Gaps
/// Call ``recordGap(reason:)`` to insert a deliberate gap marker. Sparkline
/// renderers break the polyline at gaps — no fabricated straight lines across
/// sleep/wake boundaries.
///
/// ## Thread safety
/// All mutable operations are protected by an `NSLock`. Reads that return
/// snapshots (``samples``, ``valueSamples``, ``currentMinMax``) copy the
/// underlying storage under the lock.
public final class MetricsRingBuffer: @unchecked Sendable, Codable {
    /// Maximum number of samples stored (including gap markers).
    public let capacity: Int

    private var storage: [MetricSample] = []
    private let lock = NSLock()

    // MARK: - Lifecycle

    /// Create a buffer with the given capacity.
    /// - Parameter capacity: Maximum sample count (must be ≥ 1).
    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    // MARK: - Writing

    /// Record a real-valued sample. Evicts the oldest sample if at capacity.
    public func recordValue(_ value: Double, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        _append(.sample(timestamp: timestamp, value))
    }

    /// Record a gap marker (e.g. sleep, wake, metric unavailable).
    public func recordGap(reason: String? = nil, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        _append(.gap(timestamp: timestamp, reason: reason))
    }

    /// Drop all samples. Does not change capacity.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }

    // MARK: - Reading

    /// A snapshot of all samples (values + gaps) in chronological order.
    public var samples: [MetricSample] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Only the value-bearing samples (no gaps), in chronological order.
    public var valueSamples: [MetricSample] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.isValue }
    }

    /// The number of samples currently stored (including gaps).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// Whether the buffer is empty.
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    /// The most recent value sample, if any.
    public var latestValue: Double? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last(where: { $0.isValue })?.value
    }

    /// The minimum and maximum values (across value samples only).
    /// Returns `nil` when there are no value samples.
    ///
    /// Computed in a single pass over the storage — the previous version built
    /// two intermediate arrays and then scanned twice more, which is wasteful
    /// on a path the status UI hits for every metric on every refresh.
    public var currentMinMax: (min: Double, max: Double)? {
        lock.lock()
        defer { lock.unlock() }
        var mn = Double.infinity
        var mx = -Double.infinity
        var found = false
        for sample in storage {
            guard let value = sample.value else { continue }
            found = true
            if value < mn { mn = value }
            if value > mx { mx = value }
        }
        return found ? (mn, mx) : nil
    }

    /// The time span covered by stored samples, from earliest to latest timestamp.
    /// Returns `nil` when the buffer has fewer than 2 samples.
    public var span: (start: Date, end: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = storage.first, let last = storage.last else { return nil }
        return (first.timestamp, last.timestamp)
    }

    // MARK: - Internals

    private func _append(_ sample: MetricSample) {
        storage.append(sample)
        while storage.count > capacity {
            storage.removeFirst()
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case capacity, storage
    }

    public convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cap = try c.decode(Int.self, forKey: .capacity)
        self.init(capacity: cap)
        self.storage = try c.decode([MetricSample].self, forKey: .storage)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capacity, forKey: .capacity)
        lock.lock()
        defer { lock.unlock() }
        try c.encode(storage, forKey: .storage)
    }
}

import Foundation

/// Which resource a process listing is ranked by.
public enum ProcessSortKey: String, Codable, Sendable, CaseIterable {
    case cpu
    case memory

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }
}

/// One process's resource usage at a point in time.
public struct ProcessUsage: Codable, Equatable, Sendable, Identifiable {
    public let pid: Int32
    /// Executable name (`Safari`, `kernel_task`, …).
    public let name: String
    /// Share of one CPU core, as a percentage. `200` means two cores fully
    /// busy — same convention as Activity Monitor. `nil` until a second sample
    /// exists to difference against.
    public let cpuPercent: Double?
    /// Resident memory in bytes.
    public let memoryBytes: UInt64
    /// Thread count, when the kernel reported it.
    public let threadCount: Int?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double?,
        memoryBytes: UInt64,
        threadCount: Int? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
    }
}

/// A ranked process listing.
public struct ProcessUsageReport: Codable, Equatable, Sendable {
    public let sortedBy: ProcessSortKey
    /// The top `limit` processes, ranked by ``sortedBy``.
    public let processes: [ProcessUsage]
    /// How many processes were readable in this sample.
    public let sampledProcessCount: Int
    /// How many processes exist but could not be read (other users / root).
    public let unreadableProcessCount: Int
    public let notes: [String]

    public init(
        sortedBy: ProcessSortKey,
        processes: [ProcessUsage],
        sampledProcessCount: Int,
        unreadableProcessCount: Int,
        notes: [String] = []
    ) {
        self.sortedBy = sortedBy
        self.processes = processes
        self.sampledProcessCount = sampledProcessCount
        self.unreadableProcessCount = unreadableProcessCount
        self.notes = notes
    }

    public static let empty = ProcessUsageReport(
        sortedBy: .cpu,
        processes: [],
        sampledProcessCount: 0,
        unreadableProcessCount: 0
    )
}

// MARK: - Sampling

/// A raw per-process reading, before CPU percentages exist.
public struct ProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    /// Cumulative CPU time (user + system) in nanoseconds since process start.
    public let cpuTimeNanoseconds: UInt64
    public let memoryBytes: UInt64
    public let threadCount: Int?

    public init(
        pid: Int32,
        name: String,
        cpuTimeNanoseconds: UInt64,
        memoryBytes: UInt64,
        threadCount: Int? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
    }
}

/// One sweep over the process table.
public struct ProcessSampleSet: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let samples: [ProcessSample]
    /// Processes the kernel refused to describe (a different user's, typically).
    public let unreadableCount: Int

    public init(timestamp: TimeInterval, samples: [ProcessSample], unreadableCount: Int) {
        self.timestamp = timestamp
        self.samples = samples
        self.unreadableCount = unreadableCount
    }
}

public protocol ProcessSampleSource: Sendable {
    /// Take a sweep over the process table.
    ///
    /// `knownNames` lets a caller reuse names it already resolved: a PID the
    /// source has seen before does not pay for `proc_pidpath` again. The
    /// returned tuple carries the sweep plus the names resolved *on this call*
    /// (the PIDs that were absent from `knownNames`), so the caller can keep
    /// its cache in sync without re-reading the table.
    func sample(knownNames: [Int32: String]) -> (set: ProcessSampleSet, resolvedNames: [Int32: String])
}

/// Turns two sweeps into a ranked report.
///
/// CPU usage is a *rate*, so it only exists between two samples: the first call
/// after launch reports memory and `nil` CPU rather than the meaningless
/// "average since boot" figure `ps` prints.
public enum ProcessUsageRanking: Sendable {

    /// Build a report from the newest sweep and the one before it.
    ///
    /// - Parameters:
    ///   - current: the sweep just taken.
    ///   - previous: the sweep before it, or `nil` on the first call.
    ///   - sortedBy: ranking key.
    ///   - limit: how many processes to keep.
    public static func report(
        current: ProcessSampleSet,
        previous: ProcessSampleSet?,
        sortedBy: ProcessSortKey,
        limit: Int
    ) -> ProcessUsageReport {
        let elapsed = previous.map { current.timestamp - $0.timestamp } ?? 0
        var previousCPU: [Int32: UInt64] = [:]
        if let previous, elapsed > 0 {
            previousCPU.reserveCapacity(previous.samples.count)
            for sample in previous.samples { previousCPU[sample.pid] = sample.cpuTimeNanoseconds }
        }

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(current.samples.count)
        for sample in current.samples {
            var percent: Double?
            if elapsed > 0, let before = previousCPU[sample.pid] {
                // A restarted PID can report *less* CPU time than last sweep;
                // treat that as "no usable delta" rather than underflowing.
                if sample.cpuTimeNanoseconds >= before {
                    let deltaSeconds = Double(sample.cpuTimeNanoseconds - before) / 1_000_000_000
                    percent = max(0, deltaSeconds / elapsed * 100)
                }
            }
            usages.append(ProcessUsage(
                pid: sample.pid,
                name: sample.name,
                cpuPercent: percent,
                memoryBytes: sample.memoryBytes,
                threadCount: sample.threadCount
            ))
        }

        let ranked: [ProcessUsage]
        switch sortedBy {
        case .cpu:
            ranked = usages.sorted {
                let left = $0.cpuPercent ?? -1
                let right = $1.cpuPercent ?? -1
                // Memory breaks ties, so the first sample (no CPU deltas yet)
                // still shows a meaningful ordering instead of PID order.
                if left == right { return $0.memoryBytes > $1.memoryBytes }
                return left > right
            }
        case .memory:
            ranked = usages.sorted { $0.memoryBytes > $1.memoryBytes }
        }

        var notes: [String] = []
        if elapsed <= 0 {
            notes.append("CPU percentages need a second sample; only memory is ranked so far.")
        }
        if current.unreadableCount > 0 {
            notes.append(
                "\(current.unreadableCount) processes are owned by another user (usually root) "
                + "and are not readable without elevation."
            )
        }

        return ProcessUsageReport(
            sortedBy: sortedBy,
            processes: Array(ranked.prefix(max(0, limit))),
            sampledProcessCount: current.samples.count,
            unreadableProcessCount: current.unreadableCount,
            notes: notes
        )
    }
}

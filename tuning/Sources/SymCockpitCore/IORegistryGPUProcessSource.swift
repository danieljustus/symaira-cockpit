import Foundation

/// Per-process GPU usage from the IORegistry — no root needed (issue #402).
///
/// Each process that talks to the GPU holds one or more `IOAccelerator` user
/// clients whose `AppUsage` list carries cumulative `accumulatedGPUTime`
/// counters in nanoseconds. The share a process used is a rate, so it exists
/// only between two samples:
///
///     percent = Δ accumulated GPU time / Δ wall-clock time × 100
///
/// The source is stateful. The first call only primes the baseline and reports
/// the processes with `gpuPercent == nil` plus a "measuring" note — never a
/// fabricated 0 %. A pid that disappeared, or whose counter went backwards
/// (client closed, driver reset), loses its baseline and is re-primed instead
/// of producing a bogus or negative figure.
public final class IORegistryGPUProcessSource: GPUProcessReporting, @unchecked Sendable {
    private struct Baseline {
        var uptimeNanoseconds: UInt64
        var gpuNanoseconds: [Int32: UInt64]
    }

    private let reader: any GPUClientReading
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let staleAfterNanoseconds: UInt64
    private let lock = NSLock()
    private var baseline: Baseline?

    /// - Parameters:
    ///   - reader: the registry seam; tests inject a fake.
    ///   - uptimeNanoseconds: monotonic clock; tests inject a scripted one.
    ///   - staleAfter: a baseline older than this is discarded rather than
    ///     averaged over an arbitrarily long gap.
    public init(
        reader: any GPUClientReading = IORegistryGPUReader(),
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        staleAfter: TimeInterval = 30
    ) {
        self.reader = reader
        self.uptimeNanoseconds = uptimeNanoseconds
        self.staleAfterNanoseconds = UInt64(max(0, staleAfter) * 1_000_000_000)
    }

    public func report(limit: Int) -> ProcessUsageReport {
        sample(limit: limit) ?? ProcessUsageReport(
            sortedBy: .gpu,
            processes: [],
            sampledProcessCount: 0,
            unreadableProcessCount: 0,
            notes: ["The IORegistry exposes no per-process GPU usage (AppUsage) on this Mac."]
        )
    }

    public func resetBaseline() {
        lock.lock()
        baseline = nil
        lock.unlock()
    }

    /// One sample, or `nil` when the registry exposes no `AppUsage` at all —
    /// the signal ``DefaultGPUProcessSource`` uses to fall back to powermetrics.
    func sample(limit: Int) -> ProcessUsageReport? {
        let clients = reader.readClients()
        // `AppUsage` present on at least one client (even an empty list) means
        // the registry supports per-process accounting; absent everywhere means
        // it does not (older macOS, virtualized GPU, no accelerator).
        guard clients.contains(where: { $0.accumulatedGPUTimeNanoseconds != nil }) else { return nil }
        let now = uptimeNanoseconds()

        // Sum every AppUsage entry of every client per pid; keep the name.
        var totals: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        for client in clients {
            guard let times = client.accumulatedGPUTimeNanoseconds, !times.isEmpty else { continue }
            totals[client.pid, default: 0] &+= times.reduce(0, &+)
            names[client.pid] = client.name
        }

        lock.lock()
        let previous = baseline
        // Pids absent from this sample drop out of the baseline here.
        baseline = Baseline(uptimeNanoseconds: now, gpuNanoseconds: totals)
        lock.unlock()

        var elapsed: UInt64?
        if let previous, now > previous.uptimeNanoseconds {
            let gap = now - previous.uptimeNanoseconds
            if gap <= staleAfterNanoseconds { elapsed = gap }
        }

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(totals.count)
        for (pid, total) in totals {
            var percent: Double?
            if let elapsed, let before = previous?.gpuNanoseconds[pid], total >= before {
                percent = Double(total - before) / Double(elapsed) * 100
            }
            usages.append(ProcessUsage(
                pid: pid,
                name: names[pid] ?? "pid \(pid)",
                cpuPercent: nil,
                memoryBytes: 0,
                threadCount: nil,
                gpuPercent: percent
            ))
        }

        usages.sort {
            let left = $0.gpuPercent ?? -1
            let right = $1.gpuPercent ?? -1
            if left != right { return left > right }
            return $0.pid < $1.pid
        }

        var notes: [String] = []
        if elapsed == nil {
            notes.append("Measuring — GPU percentages need a second sample; none is shown yet.")
        }
        return ProcessUsageReport(
            sortedBy: .gpu,
            processes: Array(usages.prefix(max(0, limit))),
            sampledProcessCount: usages.count,
            unreadableProcessCount: 0,
            notes: notes
        )
    }
}

/// The default GPU process source: the unprivileged IORegistry reader, with
/// `powermetrics` (root only) as the explicit fallback when the registry
/// exposes no `AppUsage`.
public final class DefaultGPUProcessSource: GPUProcessReporting, @unchecked Sendable {
    private let registry: IORegistryGPUProcessSource
    private let fallback: any GPUProcessReporting

    public init(
        registry: IORegistryGPUProcessSource = IORegistryGPUProcessSource(),
        fallback: any GPUProcessReporting = PowermetricsGPUProcessSource()
    ) {
        self.registry = registry
        self.fallback = fallback
    }

    public func report(limit: Int) -> ProcessUsageReport {
        registry.sample(limit: limit) ?? fallback.report(limit: limit)
    }

    public func resetBaseline() {
        registry.resetBaseline()
        fallback.resetBaseline()
    }
}

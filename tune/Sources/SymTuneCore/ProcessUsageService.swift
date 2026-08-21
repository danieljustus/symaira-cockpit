import Darwin
import Foundation

/// Reads the process table through `libproc`.
///
/// No shelling out to `ps`/`top`: a sweep over ~750 processes costs a few
/// milliseconds here, and `ps`'s `%cpu` is an average over the process's whole
/// lifetime, which is not what "what is using my CPU *now*" means.
public struct LibprocProcessSampleSource: ProcessSampleSource {
    public init() {}

    public func sample(knownNames: [Int32: String]) -> (set: ProcessSampleSet, resolvedNames: [Int32: String]) {
        let pids = Self.allPIDs()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        var unreadable = 0
        var resolved: [Int32: String] = [:]
        resolved.reserveCapacity(pids.count)

        for pid in pids {
            guard let info = Self.taskInfo(pid) else {
                unreadable += 1
                continue
            }
            // Only a PID seen for the first time pays for proc_pidpath; a name
            // the caller already resolved is reused as-is.
            let name: String
            if let known = knownNames[pid] {
                name = known
            } else {
                name = Self.name(of: pid)
                resolved[pid] = name
            }
            samples.append(ProcessSample(
                pid: pid,
                name: name,
                cpuTimeNanoseconds: info.pti_total_user &+ info.pti_total_system,
                memoryBytes: info.pti_resident_size,
                threadCount: Int(info.pti_threadnum)
            ))
        }

        let set = ProcessSampleSet(
            timestamp: Date.timeIntervalSinceReferenceDate,
            samples: samples,
            unreadableCount: unreadable
        )
        return (set, resolved)
    }

    // MARK: - libproc

    private static func allPIDs() -> [Int32] {
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { return [] }
        // Head-room for processes spawned between the probe and the read.
        var pids = [Int32](repeating: 0, count: Int(probe) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<Int32>.size)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written)).filter { $0 > 0 }
    }

    private static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        // Fails with EPERM for processes owned by another user — expected, and
        // reported as `unreadableProcessCount` rather than silently dropped.
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (4 × `MAXPATHLEN`) is a C macro and does not
    /// import into Swift.
    private static let pathBufferSize = 4 * 1024

    private static func name(of pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: pathBufferSize)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            if let last = full.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
        }
        // Short name is truncated to 15 characters but always available.
        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let name = String(cString: short)
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }
}

/// Stateful wrapper that keeps the previous sweep so CPU percentages can be
/// differenced. Thread-safe: the menu-bar app samples off the main thread.
public final class ProcessUsageService: @unchecked Sendable {
    /// Default number of processes reported.
    public static let defaultLimit = 6
    /// Hard cap, so an agent asking for "all" cannot produce an unbounded reply.
    public static let maximumLimit = 50

    private let source: any ProcessSampleSource
    private let lock = NSLock()
    private var previous: ProcessSampleSet?
    /// Names cached by PID so a process seen before does not pay for
    /// `proc_pidpath` on every sweep. Pruned to the PIDs seen in the current
    /// sweep (in `report`) so it cannot grow without bound and a recycled PID
    /// is re-resolved rather than reporting its predecessor's name.
    private var names: [Int32: String] = [:]

    public init(source: any ProcessSampleSource = LibprocProcessSampleSource()) {
        self.source = source
    }

    /// Take a sweep and rank it against the previous one.
    public func report(
        sortedBy: ProcessSortKey = .cpu,
        limit: Int = ProcessUsageService.defaultLimit
    ) -> ProcessUsageReport {
        lock.lock()
        let knownNames = names
        lock.unlock()

        let sweep = source.sample(knownNames: knownNames)

        lock.lock()
        // Prune the cache to this sweep's PIDs, preferring the names resolved
        // just now over the previously known ones: an exiting PID is forgotten,
        // and a recycled PID that comes back is re-resolved to its new identity.
        var nextNames: [Int32: String] = [:]
        nextNames.reserveCapacity(sweep.set.samples.count)
        for sample in sweep.set.samples {
            nextNames[sample.pid] = sweep.resolvedNames[sample.pid] ?? knownNames[sample.pid]
        }
        names = nextNames
        let last = previous
        previous = sweep.set
        lock.unlock()

        return ProcessUsageRanking.report(
            current: sweep.set,
            previous: last,
            sortedBy: sortedBy,
            limit: min(max(limit, 1), Self.maximumLimit)
        )
    }

    /// Forget the previous sweep, so the next report starts a fresh baseline.
    /// Used when the UI stops sampling: a stale baseline would make the first
    /// reading after a long pause average over the whole gap.
    public func resetBaseline() {
        lock.lock()
        previous = nil
        lock.unlock()
    }
}

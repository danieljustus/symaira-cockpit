import Darwin
import Foundation
import SymCockpitHistory

/// Supplies a GPU-ranked process report. Separate from ``ProcessSampleSource``
/// (libproc's CPU/memory sweep) because GPU data comes from a fundamentally
/// different, privileged source.
public protocol GPUProcessReporting: Sendable {
    func report(limit: Int) -> ProcessUsageReport
}

/// Per-process GPU usage via `powermetrics` — macOS's only public source for
/// it. There is no libproc/IOKit call for this the way there is for CPU time
/// and resident memory; Activity Monitor's own "% GPU" column and every
/// third-party tool that shows one reads it from the same place. Unlike CPU
/// and memory sampling, this requires root: `powermetrics` refuses to sample
/// anything at all otherwise (confirmed empirically — it exits immediately
/// with "must be invoked as the superuser", even for a single non-privileged
/// sampler). Sampling here therefore only ever produces data when this
/// process is already privileged: run via `sudo`, or re-invoked as root by
/// ``PrivilegedElevation`` on the GUI's behalf. Everywhere else, ``report``
/// returns an empty, clearly-noted result rather than guessing.
public struct PowermetricsGPUProcessSource: GPUProcessReporting {
    private let sampleIntervalMilliseconds: Int
    private let isRunningAsRoot: @Sendable () -> Bool

    public init(
        sampleIntervalMilliseconds: Int = 1000,
        isRunningAsRoot: @escaping @Sendable () -> Bool = { geteuid() == 0 }
    ) {
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        self.isRunningAsRoot = isRunningAsRoot
    }

    public func report(limit: Int) -> ProcessUsageReport {
        guard isRunningAsRoot() else {
            return Self.emptyReport(notes: [
                "GPU sampling needs root — powermetrics refuses to run otherwise. Run "
                    + "`sudo symcockpit tune processes --sort gpu`, or use the app's "
                    + "\"Load GPU usage\" action, which prompts for your administrator password.",
            ])
        }

        guard let result = try? BoundedProcessRunner.run(
            executable: "/usr/bin/powermetrics",
            arguments: [
                "-i", String(sampleIntervalMilliseconds),
                "-n", "1",
                "--samplers", "tasks",
                "--show-process-gpu",
                "-f", "plist",
            ],
            timeoutSeconds: TimeInterval(sampleIntervalMilliseconds) / 1000 + 10
        ), !result.timedOut, result.terminationStatus == 0 else {
            return Self.emptyReport(notes: ["powermetrics did not return a GPU sample."])
        }

        guard let processes = Self.parseProcessGPU(plistData: result.standardOutput), !processes.isEmpty else {
            return Self.emptyReport(notes: [
                "Could not read GPU figures from powermetrics's output — its format may have "
                    + "changed on this macOS version.",
            ])
        }

        let ranked = processes.sorted { ($0.gpuPercent ?? 0) > ($1.gpuPercent ?? 0) }
        return ProcessUsageReport(
            sortedBy: .gpu,
            processes: Array(ranked.prefix(max(0, limit))),
            sampledProcessCount: processes.count,
            unreadableProcessCount: 0
        )
    }

    private static func emptyReport(notes: [String]) -> ProcessUsageReport {
        ProcessUsageReport(sortedBy: .gpu, processes: [], sampledProcessCount: 0, unreadableProcessCount: 0, notes: notes)
    }

    // MARK: - Parsing

    /// powermetrics's `-f plist` output is one or more NUL-separated property
    /// lists (one per sample, `-n 1` here yields exactly one). The per-process
    /// table's exact key and field names are undocumented and have shifted
    /// across macOS releases, so several plausible names are tried in order
    /// before giving up — a miss returns `nil` (surfaced as a clear note by
    /// ``report(limit:)``) rather than fabricating a number.
    static func parseProcessGPU(plistData: Data) -> [ProcessUsage]? {
        let trimmed = plistData.split(separator: UInt8(0), maxSplits: 1, omittingEmptySubsequences: true).first
            .map(Data.init) ?? plistData
        guard let root = try? PropertyListSerialization.propertyList(from: trimmed, format: nil) as? [String: Any] else {
            return nil
        }

        var taskDicts: [[String: Any]] = []
        for key in ["tasks", "processes", "coalitions"] {
            if let array = root[key] as? [[String: Any]] {
                taskDicts = array
                break
            }
        }
        guard !taskDicts.isEmpty else { return nil }

        var usages: [ProcessUsage] = []
        for task in taskDicts {
            guard let name = firstString(task, keys: ["name", "process", "pname"]),
                  let pid = firstInt(task, keys: ["pid", "id"]),
                  let gpuMillisecondsPerSecond = firstDouble(task, keys: [
                      "gputime_ms_per_s", "gpu_ms_per_s", "gputime", "gpu_time_ms",
                  ]) else { continue }
            // ms of GPU time consumed per second of wall-clock sample time —
            // already a 0–100(+) percentage of one GPU's worth of time, the
            // same convention `ProcessUsage.cpuPercent` uses for CPU cores.
            usages.append(ProcessUsage(
                pid: Int32(pid),
                name: name,
                cpuPercent: nil,
                memoryBytes: 0,
                threadCount: nil,
                gpuPercent: gpuMillisecondsPerSecond / 10
            ))
        }
        return usages.isEmpty ? nil : usages
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String { return value }
        }
        return nil
    }

    private static func firstInt(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? NSNumber { return value.intValue }
            if let value = dict[key] as? Int { return value }
        }
        return nil
    }

    private static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            if let value = dict[key] as? Double { return value }
        }
        return nil
    }
}

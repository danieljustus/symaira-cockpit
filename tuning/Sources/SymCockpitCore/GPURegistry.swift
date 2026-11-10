import Foundation
import IOKit

/// GPU figures the IORegistry publishes without privileges (issue #402).
///
/// Every `IOAccelerator` service carries a `PerformanceStatistics` dictionary
/// whose `Device Utilization %` is the figure Activity Monitor's GPU history
/// graph is drawn from, and its user clients carry an `AppUsage` list whose
/// `accumulatedGPUTime` counters (nanoseconds) say which process used the GPU.
/// Reading both needs no root — unlike `powermetrics`.

/// GPU load as a block of ``SystemMetricsReport``. The whole block is omitted
/// from JSON when the registry publishes no utilization — no zeros, no guesses.
public struct GPUReport: Codable, Sendable, Equatable {
    /// Device utilization in percent (0–100), the maximum across accelerators.
    public let utilizationPercent: Double

    public init(utilizationPercent: Double) {
        self.utilizationPercent = utilizationPercent
    }
}

/// Source seam for GPU device utilization. Tests inject a fake; the real
/// reader is ``IORegistryGPUReader``.
public protocol GPUUtilizationReading: Sendable {
    /// Device utilization in percent, or `nil` when the registry publishes none.
    func readUtilizationPercent() -> Double?
}

/// One GPU user client (a process's connection to an accelerator).
public struct GPURegistryClient: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    /// `accumulatedGPUTime` (ns) of every `AppUsage` entry; `nil` when the
    /// client has no `AppUsage` key at all, `[]` when the key is present but
    /// empty (an idle client).
    public let accumulatedGPUTimeNanoseconds: [UInt64]?

    public init(pid: Int32, name: String, accumulatedGPUTimeNanoseconds: [UInt64]?) {
        self.pid = pid
        self.name = name
        self.accumulatedGPUTimeNanoseconds = accumulatedGPUTimeNanoseconds
    }
}

/// Source seam for per-process GPU time.
public protocol GPUClientReading: Sendable {
    /// Every GPU user client currently in the registry.
    func readClients() -> [GPURegistryClient]
}

/// IOKit-backed reader for both seams.
///
/// Reads single property keys only (`PerformanceStatistics`, `AppUsage`,
/// `IOUserClientCreator`) — never a whole registry subtree — and releases every
/// `io_object_t` it is handed exactly once.
public struct IORegistryGPUReader: GPUUtilizationReading, GPUClientReading {
    public init() {}

    public func readUtilizationPercent() -> Double? {
        var best: Double?
        forEachAccelerator { service in
            guard let value = Self.utilization(of: service) else { return }
            best = max(best ?? value, value)
        }
        return best
    }

    public func readClients() -> [GPURegistryClient] {
        var clients: [GPURegistryClient] = []
        forEachAccelerator { accelerator in
            var iterator: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(
                accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
            ) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iterator) }
            while case let child = IOIteratorNext(iterator), child != 0 {
                defer { IOObjectRelease(child) }
                if let client = Self.client(of: child) { clients.append(client) }
            }
        }
        return clients
    }

    // MARK: - Registry walking

    private func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        guard let matching = IOServiceMatching("IOAccelerator") else { return }
        var iterator: io_iterator_t = 0
        // Consumes `matching`.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            body(service)
        }
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func utilization(of service: io_registry_entry_t) -> Double? {
        guard let statistics = property("PerformanceStatistics", of: service) as? [String: Any] else { return nil }
        return utilizationPercent(fromStatistics: statistics)
    }

    private static func client(of entry: io_registry_entry_t) -> GPURegistryClient? {
        guard let creator = property("IOUserClientCreator", of: entry) as? String,
              let (pid, name) = parseCreator(creator) else { return nil }
        let usage = (property("AppUsage", of: entry) as? [[String: Any]])
            .map { entries in entries.compactMap { accumulatedTime(of: $0) } }
        return GPURegistryClient(pid: pid, name: name, accumulatedGPUTimeNanoseconds: usage)
    }

    // MARK: - Parsing (pure, unit-tested)

    /// `Device Utilization %` from a `PerformanceStatistics` dictionary,
    /// clamped to 0–100. `nil` when the key is absent or not a number.
    static func utilizationPercent(fromStatistics statistics: [String: Any]) -> Double? {
        guard let number = statistics["Device Utilization %"] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    /// Splits an `IOUserClientCreator` such as `"pid 417, WindowServer"`.
    static func parseCreator(_ creator: String) -> (pid: Int32, name: String)? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (pid, name.isEmpty ? "pid \(pid)" : name)
    }

    private static func accumulatedTime(of entry: [String: Any]) -> UInt64? {
        guard let number = entry["accumulatedGPUTime"] as? NSNumber, number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }
}

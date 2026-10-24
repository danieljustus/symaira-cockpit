import Foundation
import Darwin

public struct CPUStatistics: Sendable, Equatable {
    public let total: [UInt64]
    public let perCore: [[UInt64]]
    public init(total: [UInt64], perCore: [[UInt64]]) {
        self.total = total
        self.perCore = perCore
    }
}

public struct MemoryStatistics: Sendable, Equatable {
    public let usedBytes: UInt64?
    public let freeBytes: UInt64?
    public let wiredBytes: UInt64?
    public let compressedBytes: UInt64?
    public let pressure: String?
    public init(
        usedBytes: UInt64?,
        freeBytes: UInt64?,
        wiredBytes: UInt64?,
        compressedBytes: UInt64?,
        pressure: String?
    ) {
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.pressure = pressure
    }
    public static let empty = MemoryStatistics(usedBytes: nil, freeBytes: nil, wiredBytes: nil, compressedBytes: nil, pressure: nil)
}

public struct DiskStatistics: Sendable, Equatable {
    public let capacityBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public init(capacityBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64) {
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
    }
}

public struct NetworkInterfaceStatistics: Sendable, Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) { self.name = name; self.bytesIn = bytesIn; self.bytesOut = bytesOut }
}

public struct SystemMetricsSnapshot: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let cpu: CPUStatistics
    public let memory: MemoryStatistics
    public let disk: DiskStatistics?
    public let network: [NetworkInterfaceStatistics]
    /// Live DC-in power draw; nil when the SMC does not expose the keys.
    public let power: PowerReport?
    public let volumes: [StorageVolumeReport]
    public init(
        timestamp: TimeInterval = 0,
        cpu: CPUStatistics,
        memory: MemoryStatistics,
        disk: DiskStatistics?,
        network: [NetworkInterfaceStatistics],
        power: PowerReport? = nil,
        volumes: [StorageVolumeReport] = []
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.power = power
        self.volumes = volumes
    }
    public static let empty = SystemMetricsSnapshot(timestamp: 0, cpu: .init(total: [], perCore: []), memory: .empty, disk: nil, network: [])
}

public protocol SystemMetricsSource: Sendable { func readSnapshot() -> SystemMetricsSnapshot }

public struct HardwareSystemMetricsSource: SystemMetricsSource, Sendable {
    private let smc: SMCService

    public init(smc: SMCService = SMCService()) {
        self.smc = smc
    }

    public func readSnapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            timestamp: Date.timeIntervalSinceReferenceDate,
            cpu: readCPU(),
            memory: readMemory(),
            disk: readDisk(),
            network: readNetwork(),
            power: smc.readSystemPower(),
            volumes: StorageVolumeService().read()
        )
    }

    private func readCPU() -> CPUStatistics {
        var processorCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return CPUStatistics(total: [], perCore: []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        var cores = [[UInt64]]()
        for core in 0..<Int(processorCount) {
            let start = core * stride
            cores.append((0..<stride).map { UInt64(max(0, Int(info[start + $0]))) })
        }
        let total = (0..<stride).map { index in cores.reduce(UInt64(0)) { $0 &+ $1[index] } }
        return CPUStatistics(total: total, perCore: cores)
    }

    private func readMemory() -> MemoryStatistics {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return .empty }
        var pageSizeValue: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeValue) == KERN_SUCCESS else { return .empty }
        return Self.memoryStatistics(
            internalPages: UInt64(vmStats.internal_page_count),
            purgeablePages: UInt64(vmStats.purgeable_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressorPages: UInt64(vmStats.compressor_page_count),
            pageSize: UInt64(pageSizeValue),
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Memory use as Activity Monitor counts it (issue #384).
    ///
    /// "Memory Used" there is App Memory + Wired + Compressed, where App Memory
    /// is the anonymous (internal) pages less the purgeable ones. Counting the
    /// *active* pages instead mixes in file cache and drops inactive app memory,
    /// which put the readout well over a gigabyte below Activity Monitor's.
    /// Everything else — file cache, purgeable and free pages — is memory macOS
    /// hands out on demand, so available is simply physical memory less used,
    /// and the two always add up.
    static func memoryStatistics(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        pageSize: UInt64,
        physicalMemory: UInt64
    ) -> MemoryStatistics {
        let appMemory = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressorPages * pageSize
        let used = min(appMemory &+ wired &+ compressed, physicalMemory)
        let available = physicalMemory - used
        return MemoryStatistics(
            usedBytes: used,
            freeBytes: available,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressure: pressureLevel(availableBytes: available, physicalMemory: physicalMemory)
        )
    }

    private static func pressureLevel(availableBytes: UInt64, physicalMemory: UInt64) -> String? {
        guard physicalMemory > 0 else { return nil }
        let availableRatio = Double(availableBytes) / Double(physicalMemory)
        switch availableRatio {
        case ..<0.05:
            return "critical"
        case ..<0.10:
            return "warning"
        default:
            return "nominal"
        }
    }

    /// Boot-volume capacity, as macOS itself reports it.
    ///
    /// Two things have to match Finder and System Settings › Storage, or the
    /// reading is quietly tens of gigabytes off:
    ///
    /// - **Which "free" figure.** `statfs`'s `f_bfree` counts only blocks that
    ///   are free *right now*. macOS reports what an app can actually claim,
    ///   which also covers purgeable content — caches and local Time Machine
    ///   snapshots the system evicts on demand. That is
    ///   `volumeAvailableCapacityForImportantUsage`; on a nearly full disk the
    ///   two differ by hundreds of megabytes to several gigabytes, and every
    ///   such byte lands in the used figure.
    /// - **Which volume.** `/` is the sealed read-only system snapshot, so the
    ///   resource values are asked of the data volume; both report the shared
    ///   APFS container, but only the data volume answers the availability
    ///   question the Storage pane asks.
    ///
    /// `statfs` stays as the fallback for the case where neither URL yields
    /// resource values.
    private func readDisk() -> DiskStatistics? {
        for path in ["/System/Volumes/Data", "/"] {
            if let stats = readDiskResourceValues(at: path) { return stats }
        }
        return readDiskStatfs()
    }

    private func readDiskResourceValues(at path: String) -> DiskStatistics? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values.flatMap(StorageVolumeService.statistics)
    }

    private func readDiskStatfs() -> DiskStatistics? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let blockSize = UInt64(stats.f_bsize)
        let capacity = UInt64(stats.f_blocks) * blockSize
        let free = UInt64(stats.f_bfree) * blockSize
        return DiskStatistics(capacityBytes: capacity, usedBytes: capacity >= free ? capacity - free : 0, freeBytes: free)
    }

    private func readNetwork() -> [NetworkInterfaceStatistics] {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return [] }
        defer { freeifaddrs(first) }
        var merged = [String: NetworkInterfaceStatistics]()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let address = current {
            if let name = String(validatingCString: address.pointee.ifa_name), let data = address.pointee.ifa_data {
                let item = data.assumingMemoryBound(to: if_data.self).pointee
                let value = NetworkInterfaceStatistics(name: name, bytesIn: UInt64(item.ifi_ibytes), bytesOut: UInt64(item.ifi_obytes))
                if let old = merged[name] { merged[name] = .init(name: name, bytesIn: old.bytesIn &+ value.bytesIn, bytesOut: old.bytesOut &+ value.bytesOut) } else { merged[name] = value }
            }
            current = address.pointee.ifa_next
        }
        return merged.values.sorted { $0.name < $1.name }
    }
}

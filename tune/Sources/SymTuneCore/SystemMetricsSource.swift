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
    public init(
        timestamp: TimeInterval = 0,
        cpu: CPUStatistics,
        memory: MemoryStatistics,
        disk: DiskStatistics?,
        network: [NetworkInterfaceStatistics],
        power: PowerReport? = nil
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.power = power
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
            power: smc.readSystemPower()
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
        let pageSize = UInt64(pageSizeValue)
        let free = UInt64(vmStats.free_count) * pageSize
        let inactive = UInt64(vmStats.inactive_count) * pageSize
        let speculative = UInt64(vmStats.speculative_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        let active = UInt64(vmStats.active_count) * pageSize
        let available = free &+ inactive &+ speculative
        let used = active &+ wired &+ compressed
        return MemoryStatistics(
            usedBytes: used,
            freeBytes: available,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressure: pressureLevel(availableBytes: available)
        )
    }

    private func pressureLevel(availableBytes: UInt64) -> String? {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
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

    private func readDisk() -> DiskStatistics? {
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

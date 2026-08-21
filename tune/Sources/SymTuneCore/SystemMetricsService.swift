import Foundation
import Darwin

public final class SystemMetricsService: @unchecked Sendable {
    private let source: any SystemMetricsSource
    private var previous: SystemMetricsSnapshot?
    private let lock = NSLock()
    public init(source: any SystemMetricsSource = HardwareSystemMetricsSource()) { self.source = source }

    public func read() -> SystemMetricsReport {
        let current = source.readSnapshot()
        lock.lock(); defer { lock.unlock() }
        let old = previous; previous = current
        let cpu = CPUReport(
            totalUtilization: utilization(current.cpu.total, old?.cpu.total),
            perCoreUtilization: current.cpu.perCore.enumerated().compactMap { index, values in
                utilization(values, old?.cpu.perCore[safe: index])
            }
        )
        let memory = MemoryReport(
            usedBytes: current.memory.usedBytes,
            freeBytes: current.memory.freeBytes,
            wiredBytes: current.memory.wiredBytes,
            compressedBytes: current.memory.compressedBytes,
            pressure: current.memory.pressure
        )
        let disk = current.disk.map { DiskReport(capacityBytes: $0.capacityBytes, usedBytes: $0.usedBytes, freeBytes: $0.freeBytes) }
        let interval = old.map { current.timestamp - $0.timestamp }
        let oldNetwork = Dictionary(uniqueKeysWithValues: (old?.network ?? []).map { ($0.name, $0) })
        let interfaces = current.network.map { item in
            let prior = oldNetwork[item.name]
            return NetworkInterfaceReport(
                name: item.name,
                bytesIn: item.bytesIn,
                bytesOut: item.bytesOut,
                bytesInPerSecond: rate(item.bytesIn, prior?.bytesIn, interval),
                bytesOutPerSecond: rate(item.bytesOut, prior?.bytesOut, interval)
            )
        }
        let aggregateIn = current.network.reduce(UInt64(0)) { $0 &+ $1.bytesIn }
        let aggregateOut = current.network.reduce(UInt64(0)) { $0 &+ $1.bytesOut }
        let priorIn = old?.network.reduce(UInt64(0)) { $0 &+ $1.bytesIn }
        let priorOut = old?.network.reduce(UInt64(0)) { $0 &+ $1.bytesOut }
        let network = NetworkReport(
            interfaces: interfaces,
            aggregateBytesIn: aggregateIn,
            aggregateBytesOut: aggregateOut,
            aggregateBytesInPerSecond: rate(aggregateIn, priorIn, interval),
            aggregateBytesOutPerSecond: rate(aggregateOut, priorOut, interval)
        )
        var notes = [String]()
        if old == nil { notes.append("Rates and CPU utilization require a previous sample.") }
        if current.cpu.total.isEmpty { notes.append("CPU metrics unavailable.") }
        if current.memory.usedBytes == nil { notes.append("Memory metrics unavailable.") }
        if current.disk == nil { notes.append("Boot-volume disk metrics unavailable.") }
        if current.network.isEmpty { notes.append("Network metrics unavailable.") }
        if current.power == nil { notes.append("Live power draw unavailable — SMC DC-in keys (VD0R/ID0R/PDTR) not exposed.") }
        return SystemMetricsReport(
            cpu: cpu,
            memory: memory,
            disk: disk,
            network: network,
            power: current.power,
            notes: notes
        )
    }

    private func utilization(_ current: [UInt64], _ old: [UInt64]?) -> Double? {
        guard let old, current.count == old.count, current.count >= 4 else { return nil }
        let deltas = zip(current, old).map { $0.0 &- $0.1 }; let total = deltas.reduce(UInt64(0), &+)
        guard total > 0 else { return nil }; return Double(total &- deltas[Int(CPU_STATE_IDLE)]) / Double(total)
    }
    private func rate(_ current: UInt64, _ old: UInt64?, _ interval: TimeInterval?) -> Double? {
        guard let old, let interval, interval > 0 else { return nil }
        return Double(current &- old) / interval
    }
}
private extension Array { subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }

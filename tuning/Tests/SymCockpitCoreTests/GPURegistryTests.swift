import XCTest
@testable import SymCockpitCore

/// Scripted registry: each `readClients()` pops the next scripted snapshot
/// (the last one repeats). Never touches IOKit.
private final class FakeGPURegistry: GPUClientReading, GPUUtilizationReading, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[GPURegistryClient]]
    var utilization: Double?

    init(_ snapshots: [[GPURegistryClient]], utilization: Double? = nil) {
        self.snapshots = snapshots
        self.utilization = utilization
    }

    func readClients() -> [GPURegistryClient] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? [])
    }

    func readUtilizationPercent() -> Double? { utilization }
}

final class GPUParsingTests: XCTestCase {
    func testParsesCreatorString() {
        XCTAssertEqual(IORegistryGPUReader.parseCreator("pid 417, WindowServer")?.pid, 417)
        XCTAssertEqual(IORegistryGPUReader.parseCreator("pid 417, WindowServer")?.name, "WindowServer")
        XCTAssertEqual(IORegistryGPUReader.parseCreator("pid 12, Name, With Comma")?.name, "Name, With Comma")
        XCTAssertEqual(IORegistryGPUReader.parseCreator("pid 12")?.name, "pid 12")
        XCTAssertNil(IORegistryGPUReader.parseCreator("kernel"))
        XCTAssertNil(IORegistryGPUReader.parseCreator("pid x, nope"))
    }

    func testUtilizationIsReadFromTheSingleKeyAndClamped() {
        XCTAssertEqual(IORegistryGPUReader.utilizationPercent(fromStatistics: ["Device Utilization %": 37]), 37)
        XCTAssertEqual(IORegistryGPUReader.utilizationPercent(fromStatistics: ["Device Utilization %": 250]), 100)
        XCTAssertEqual(IORegistryGPUReader.utilizationPercent(fromStatistics: ["Device Utilization %": -4]), 0)
    }

    func testUtilizationAbsentWhenKeyMissingOrNotANumber() {
        XCTAssertNil(IORegistryGPUReader.utilizationPercent(fromStatistics: [:]))
        XCTAssertNil(IORegistryGPUReader.utilizationPercent(fromStatistics: ["Tiler Utilization %": 5]))
        XCTAssertNil(IORegistryGPUReader.utilizationPercent(fromStatistics: ["Device Utilization %": "n/a"]))
    }
}

final class GPUMetricsReportTests: XCTestCase {
    private func snapshot(gpu: GPUReport?) -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            timestamp: 1, cpu: .init(total: [], perCore: []), memory: .empty, disk: nil, network: [], gpu: gpu
        )
    }

    func testHardwareSourceUsesInjectedUtilizationReader() {
        let source = HardwareSystemMetricsSource(gpu: FakeGPURegistry([], utilization: 12.5))
        XCTAssertEqual(source.readSnapshot().gpu?.utilizationPercent, 12.5)
        let none = HardwareSystemMetricsSource(gpu: FakeGPURegistry([], utilization: nil))
        XCTAssertNil(none.readSnapshot().gpu)
    }
}

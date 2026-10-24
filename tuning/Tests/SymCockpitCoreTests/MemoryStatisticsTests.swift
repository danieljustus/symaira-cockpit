import XCTest
@testable import SymCockpitCore

/// The memory readout counts what Activity Monitor calls "Memory Used"
/// (issue #384): App Memory (internal pages less purgeable) + Wired +
/// Compressed.
final class MemoryStatisticsTests: XCTestCase {
    private let page: UInt64 = 16_384
    private let physical: UInt64 = 24 * 1_073_741_824

    /// Page counts from `vm_stat` on a 24 GB MacBook Pro, where Activity
    /// Monitor's formula gives 18.07 GiB.
    func testUsedMatchesActivityMonitorsFormula() {
        let stats = HardwareSystemMetricsSource.memoryStatistics(
            internalPages: 524_529,
            purgeablePages: 7_050,
            wiredPages: 235_041,
            compressorPages: 397_504,
            pageSize: page,
            physicalMemory: physical
        )
        XCTAssertEqual(stats.usedBytes, (524_529 - 7_050 + 235_041 + 397_504) * page)
        XCTAssertEqual(Double(stats.usedBytes ?? 0) / 1_073_741_824, 17.55, accuracy: 0.01)
        XCTAssertEqual(stats.wiredBytes, 235_041 * page)
        XCTAssertEqual(stats.compressedBytes, 397_504 * page)
    }

    func testUsedAndAvailableAddUpToPhysicalMemory() {
        let stats = HardwareSystemMetricsSource.memoryStatistics(
            internalPages: 300_000,
            purgeablePages: 2_000,
            wiredPages: 150_000,
            compressorPages: 50_000,
            pageSize: page,
            physicalMemory: physical
        )
        XCTAssertEqual((stats.usedBytes ?? 0) + (stats.freeBytes ?? 0), physical)
        XCTAssertEqual(stats.pressure, "nominal")
    }

    /// Counters sampled a moment apart can momentarily overshoot; the readout
    /// clamps instead of wrapping around.
    func testOvershootClampsToPhysicalMemory() {
        let stats = HardwareSystemMetricsSource.memoryStatistics(
            internalPages: 2_000_000,
            purgeablePages: 3_000_000,
            wiredPages: 1_000_000,
            compressorPages: 1_000_000,
            pageSize: page,
            physicalMemory: physical
        )
        XCTAssertEqual(stats.usedBytes, physical)
        XCTAssertEqual(stats.freeBytes, 0)
        XCTAssertEqual(stats.pressure, "critical")
    }
}

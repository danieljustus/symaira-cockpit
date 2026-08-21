import XCTest
@testable import SymTuneCore

final class MetricsHistoryServiceTests: XCTestCase {

    func testEnsureBuffersCreatesForEnabled() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu, .memory])

        XCTAssertNotNil(svc.buffer(for: .cpu))
        XCTAssertNotNil(svc.buffer(for: .memory))
        XCTAssertNil(svc.buffer(for: .disk))
        XCTAssertNil(svc.buffer(for: .network))
    }

    func testEnsureBuffersDropsDisabled() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu, .memory, .disk])

        // Record some data
        let report = makeReport(cpuUtil: 0.5, memUsed: 8_589_934_592, diskUsed: 50_000_000_000, diskCap: 250_000_000_000, netDown: 1024, netUp: 512)
        svc.record(report)
        svc.record(report)

        XCTAssertEqual(svc.samples(for: .cpu).count, 2)
        XCTAssertEqual(svc.samples(for: .memory).count, 2)
        XCTAssertEqual(svc.samples(for: .disk).count, 2)

        // Now disable disk
        svc.ensureBuffers(for: [.cpu, .memory])
        XCTAssertNotNil(svc.buffer(for: .cpu))
        XCTAssertNotNil(svc.buffer(for: .memory))
        XCTAssertNil(svc.buffer(for: .disk)) // dropped

        // Disk buffer should be gone
        XCTAssertEqual(svc.samples(for: .disk), [])
    }

    func testRecordExtractsCorrectValues() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu, .memory, .disk, .network])

        let report = makeReport(
            cpuUtil: 0.75,
            memUsed: 16_000_000_000,
            diskUsed: 100_000_000_000,
            diskCap: 500_000_000_000,
            netDown: 2_097_152,
            netUp: 1_048_576
        )
        svc.record(report)

        // CPU: 0.75 * 100 = 75.0
        let cpuSamples = svc.samples(for: .cpu)
        XCTAssertEqual(cpuSamples.count, 1)
        XCTAssertEqual(cpuSamples[0].value, 75.0)

        // Memory: 16_000_000_000 bytes
        let memSamples = svc.samples(for: .memory)
        XCTAssertEqual(memSamples.count, 1)
        XCTAssertEqual(memSamples[0].value, 16_000_000_000.0)

        // Disk: 20% used
        let diskSamples = svc.samples(for: .disk)
        XCTAssertEqual(diskSamples.count, 1)
        XCTAssertEqual(diskSamples[0].value, 20.0)

        // Network: 2_097_152 + 1_048_576 = 3_145_728
        let netSamples = svc.samples(for: .network)
        XCTAssertEqual(netSamples.count, 1)
        XCTAssertEqual(netSamples[0].value, 3_145_728.0)
    }

    func testRecordInsertsGapsForUnavailableMetrics() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu, .memory, .disk, .network])

        // Create a report where CPU and disk are nil/unavailable
        let report = SystemMetricsReport(
            cpu: CPUReport(totalUtilization: nil, perCoreUtilization: []),
            memory: MemoryReport(usedBytes: 1_000_000, freeBytes: nil, wiredBytes: nil, compressedBytes: nil, pressure: nil),
            disk: nil,
            network: NetworkReport(
                interfaces: [],
                aggregateBytesIn: 0, aggregateBytesOut: 0,
                aggregateBytesInPerSecond: nil, aggregateBytesOutPerSecond: nil
            ),
            notes: []
        )
        svc.record(report)

        // CPU and disk should have gap markers, memory should have a value
        let cpuSamples = svc.samples(for: .cpu)
        XCTAssertEqual(cpuSamples.count, 1)
        XCTAssertNil(cpuSamples[0].value)
        XCTAssertEqual(cpuSamples[0].gapReason, "unavailable")

        let diskSamples = svc.samples(for: .disk)
        XCTAssertEqual(diskSamples.count, 1)
        XCTAssertNil(diskSamples[0].value)
        XCTAssertEqual(diskSamples[0].gapReason, "unavailable")

        let memSamples = svc.samples(for: .memory)
        XCTAssertEqual(memSamples.count, 1)
        XCTAssertEqual(memSamples[0].value, 1_000_000.0)

        let netSamples = svc.samples(for: .network)
        XCTAssertEqual(netSamples.count, 1)
        XCTAssertNil(netSamples[0].value)
        XCTAssertEqual(netSamples[0].gapReason, "unavailable")
    }

    func testRecordWakeGap() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu, .memory])

        svc.record(makeReport())
        svc.recordWakeGap()

        let cpuSamples = svc.samples(for: .cpu)
        XCTAssertEqual(cpuSamples.count, 2)
        XCTAssertNotNil(cpuSamples[0].value)
        XCTAssertNil(cpuSamples[1].value)
        XCTAssertEqual(cpuSamples[1].gapReason, "sleep")

        let memSamples = svc.samples(for: .memory)
        XCTAssertEqual(memSamples.count, 2)
        XCTAssertNotNil(memSamples[0].value)
        XCTAssertNil(memSamples[1].value)
        XCTAssertEqual(memSamples[1].gapReason, "sleep")
    }

    func testRecordWakeGapOnlyAffectsActiveBuffers() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu]) // only CPU enabled

        svc.recordWakeGap()
        // Should not create a buffer for memory
        XCTAssertNil(svc.buffer(for: .memory))
        // CPU buffer should have one gap
        XCTAssertEqual(svc.samples(for: .cpu).count, 1)
    }

    func testStats() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu])

        let r1 = makeReport(cpuUtil: 0.25)
        let r2 = makeReport(cpuUtil: 0.50)
        let r3 = makeReport(cpuUtil: 0.75)

        svc.record(r1)
        svc.record(r2)
        svc.record(r3)

        guard let stats = svc.stats(for: .cpu) else {
            XCTFail("Expected stats")
            return
        }
        XCTAssertEqual(stats.current, 75.0)
        XCTAssertEqual(stats.min, 25.0)
        XCTAssertEqual(stats.max, 75.0)
    }

    func testStatsNilForUnknownMetric() {
        let svc = MetricsHistoryService(capacity: 10)
        XCTAssertNil(svc.stats(for: .cpu))
    }

    func testSamplesEmptyForUnknownMetric() {
        let svc = MetricsHistoryService(capacity: 10)
        XCTAssertEqual(svc.samples(for: .disk), [])
    }

    func testDropHistory() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.cpu])
        svc.record(makeReport(cpuUtil: 0.5))
        XCTAssertNotNil(svc.buffer(for: .cpu))

        svc.dropHistory(for: .cpu)
        XCTAssertNil(svc.buffer(for: .cpu))
        XCTAssertEqual(svc.samples(for: .cpu), [])
    }

    func testNetworkWithOnlyDown() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.network])

        let report = SystemMetricsReport(
            cpu: CPUReport(totalUtilization: nil, perCoreUtilization: []),
            memory: MemoryReport(usedBytes: nil, freeBytes: nil, wiredBytes: nil, compressedBytes: nil, pressure: nil),
            disk: nil,
            network: NetworkReport(
                interfaces: [],
                aggregateBytesIn: 0, aggregateBytesOut: 0,
                aggregateBytesInPerSecond: 5000, aggregateBytesOutPerSecond: nil
            ),
            notes: []
        )
        svc.record(report)

        let samples = svc.samples(for: .network)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 5000.0)
    }

    func testNetworkWithOnlyUp() {
        let svc = MetricsHistoryService(capacity: 10)
        svc.ensureBuffers(for: [.network])

        let report = SystemMetricsReport(
            cpu: CPUReport(totalUtilization: nil, perCoreUtilization: []),
            memory: MemoryReport(usedBytes: nil, freeBytes: nil, wiredBytes: nil, compressedBytes: nil, pressure: nil),
            disk: nil,
            network: NetworkReport(
                interfaces: [],
                aggregateBytesIn: 0, aggregateBytesOut: 0,
                aggregateBytesInPerSecond: nil, aggregateBytesOutPerSecond: 2000
            ),
            notes: []
        )
        svc.record(report)

        let samples = svc.samples(for: .network)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 2000.0)
    }

    // MARK: - Helpers

    private func makeReport(
        cpuUtil: Double = 0.5,
        memUsed: UInt64 = 8_589_934_592,
        diskUsed: UInt64 = 50_000_000_000,
        diskCap: UInt64 = 250_000_000_000,
        netDown: Double = 1024,
        netUp: Double = 512
    ) -> SystemMetricsReport {
        SystemMetricsReport(
            cpu: CPUReport(totalUtilization: cpuUtil, perCoreUtilization: []),
            memory: MemoryReport(
                usedBytes: memUsed,
                freeBytes: nil,
                wiredBytes: nil,
                compressedBytes: nil,
                pressure: nil
            ),
            disk: DiskReport(capacityBytes: diskCap, usedBytes: diskUsed, freeBytes: diskCap - diskUsed),
            network: NetworkReport(
                interfaces: [],
                aggregateBytesIn: 0,
                aggregateBytesOut: 0,
                aggregateBytesInPerSecond: netDown,
                aggregateBytesOutPerSecond: netUp
            ),
            notes: []
        )
    }
}

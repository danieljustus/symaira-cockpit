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

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 1_000_000_000
    func advance(seconds: Double) {
        lock.lock(); now += UInt64(seconds * 1_000_000_000); lock.unlock()
    }
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return now }
}

private final class RecordingFallback: GPUProcessReporting, @unchecked Sendable {
    private(set) var calls = 0
    private(set) var resets = 0
    func report(limit: Int) -> ProcessUsageReport {
        calls += 1
        return ProcessUsageReport(
            sortedBy: .gpu, processes: [], sampledProcessCount: 0, unreadableProcessCount: 0,
            notes: ["fallback"]
        )
    }
    func resetBaseline() { resets += 1 }
}

private func client(_ pid: Int32, _ name: String, _ times: [UInt64]?) -> GPURegistryClient {
    GPURegistryClient(pid: pid, name: name, accumulatedGPUTimeNanoseconds: times)
}

final class IORegistryGPUProcessSourceTests: XCTestCase {

    private func makeSource(
        _ snapshots: [[GPURegistryClient]],
        clock: FakeClock,
        staleAfter: TimeInterval = 30
    ) -> IORegistryGPUProcessSource {
        IORegistryGPUProcessSource(
            reader: FakeGPURegistry(snapshots),
            uptimeNanoseconds: { clock.read() },
            staleAfter: staleAfter
        )
    }

    func testFirstSamplePrimesBaselineAndReportsMeasuringNotZero() throws {
        let clock = FakeClock()
        let source = makeSource([[client(10, "Game", [5_000_000_000])]], clock: clock)

        let report = source.report(limit: 5)

        XCTAssertEqual(report.sortedBy, .gpu)
        XCTAssertEqual(report.processes.map(\.pid), [10])
        XCTAssertNil(report.processes[0].gpuPercent, "first sample must not invent 0 %")
        XCTAssertTrue(report.notes.contains { $0.contains("Measuring") })
    }

    func testSecondSampleComputesDeltaOverWallTime() throws {
        let clock = FakeClock()
        let source = makeSource([
            [client(10, "Game", [5_000_000_000]), client(20, "Idle", [100])],
            // Game used 0.5 s of GPU time over 2 s of wall clock = 25 %.
            [client(10, "Game", [5_500_000_000]), client(20, "Idle", [100])],
        ], clock: clock)

        _ = source.report(limit: 5)
        clock.advance(seconds: 2)
        let report = source.report(limit: 5)

        XCTAssertEqual(report.processes.map(\.pid), [10, 20])
        XCTAssertEqual(try XCTUnwrap(report.processes[0].gpuPercent), 25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.processes[1].gpuPercent), 0, accuracy: 0.0001)
        XCTAssertFalse(report.notes.contains { $0.contains("Measuring") })
        XCTAssertEqual(report.sampledProcessCount, 2)
    }

    func testSumsEveryAppUsageEntryAndEveryClientOfAPid() throws {
        let clock = FakeClock()
        let source = makeSource([
            [client(7, "WindowServer", [1_000_000_000, 10]), client(7, "WindowServer", [2_000_000_000])],
            [client(7, "WindowServer", [1_100_000_000, 10]), client(7, "WindowServer", [2_300_000_000])],
        ], clock: clock)

        _ = source.report(limit: 5)
        clock.advance(seconds: 1)
        let report = source.report(limit: 5)

        // (0.1 + 0.3) s over 1 s.
        XCTAssertEqual(report.processes.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.processes[0].gpuPercent), 40, accuracy: 0.0001)
    }

    func testClientWithEmptyAppUsageIsNotListed() {
        let clock = FakeClock()
        let source = makeSource([[client(1, "Idle", []), client(2, "Busy", [10])]], clock: clock)
        XCTAssertEqual(source.report(limit: 5).processes.map(\.pid), [2])
    }

    func testCounterResetDropsTheStaleBaselineForThatPid() throws {
        let clock = FakeClock()
        let source = makeSource([
            [client(10, "Game", [9_000_000_000]), client(20, "Other", [1_000_000_000])],
            // Game's counter went backwards (client closed / driver reset).
            [client(10, "Game", [1_000]), client(20, "Other", [1_500_000_000])],
            [client(10, "Game", [500_001_000]), client(20, "Other", [1_500_000_000])],
        ], clock: clock)

        _ = source.report(limit: 5)
        clock.advance(seconds: 1)
        let reset = source.report(limit: 5)
        XCTAssertEqual(reset.processes.map(\.pid), [20, 10])
        XCTAssertEqual(try XCTUnwrap(reset.processes[0].gpuPercent), 50, accuracy: 0.0001)
        XCTAssertNil(reset.processes[1].gpuPercent, "a reset counter is dropped, never negative")

        // The reset sample became the new baseline, so the next interval works.
        clock.advance(seconds: 1)
        let recovered = source.report(limit: 5)
        XCTAssertEqual(try XCTUnwrap(recovered.processes.first { $0.pid == 10 }?.gpuPercent), 50, accuracy: 0.0001)
    }

    func testPidThatDisappearedLosesItsBaseline() {
        let clock = FakeClock()
        // Client 99 stays (idle) so the registry keeps advertising AppUsage.
        let source = makeSource([
            [client(10, "Game", [1_000_000_000]), client(99, "Idle", [])],
            [client(99, "Idle", [])],
            [client(10, "Game", [1_200_000_000]), client(99, "Idle", [])],
        ], clock: clock)

        _ = source.report(limit: 5)
        clock.advance(seconds: 1)
        XCTAssertTrue(source.report(limit: 5).processes.isEmpty)
        clock.advance(seconds: 1)
        let back = source.report(limit: 5)
        // Pid 10 returned after a gap: no baseline, so no percentage (not a
        // 200 ms / 2 s figure computed from a stale counter).
        XCTAssertNil(back.processes.first { $0.pid == 10 }?.gpuPercent)
    }

    func testBaselineOlderThanStaleLimitIsReprimed() {
        let clock = FakeClock()
        let source = makeSource([
            [client(10, "Game", [1_000_000_000])],
            [client(10, "Game", [2_000_000_000])],
        ], clock: clock, staleAfter: 5)

        _ = source.report(limit: 5)
        clock.advance(seconds: 60)
        let report = source.report(limit: 5)

        XCTAssertNil(report.processes[0].gpuPercent)
        XCTAssertTrue(report.notes.contains { $0.contains("Measuring") })
    }

    func testResetBaselineStartsOver() {
        let clock = FakeClock()
        let source = makeSource([
            [client(10, "Game", [1_000_000_000])],
            [client(10, "Game", [2_000_000_000])],
        ], clock: clock)

        _ = source.report(limit: 5)
        source.resetBaseline()
        clock.advance(seconds: 1)

        XCTAssertNil(source.report(limit: 5).processes[0].gpuPercent)
    }

    func testLimitKeepsTheBusiestProcesses() throws {
        let clock = FakeClock()
        let source = makeSource([
            [client(1, "A", [0]), client(2, "B", [0]), client(3, "C", [0])],
            [client(1, "A", [100_000_000]), client(2, "B", [900_000_000]), client(3, "C", [500_000_000])],
        ], clock: clock)

        _ = source.report(limit: 2)
        clock.advance(seconds: 1)
        let report = source.report(limit: 2)

        XCTAssertEqual(report.processes.map(\.pid), [2, 3])
        XCTAssertEqual(report.sampledProcessCount, 3)
    }

    // MARK: - Fallback selection

    func testRegistryWithoutAppUsageSelectsPowermetricsFallback() {
        let clock = FakeClock()
        let registry = makeSource([[client(1, "NoUsage", nil)]], clock: clock)
        let fallback = RecordingFallback()
        let source = DefaultGPUProcessSource(registry: registry, fallback: fallback)

        let report = source.report(limit: 5)

        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(report.notes, ["fallback"])
    }

    func testEmptyRegistrySelectsFallback() {
        let clock = FakeClock()
        let fallback = RecordingFallback()
        let source = DefaultGPUProcessSource(registry: makeSource([[]], clock: clock), fallback: fallback)

        _ = source.report(limit: 5)

        XCTAssertEqual(fallback.calls, 1)
    }

    func testRegistryWithAppUsageDoesNotTouchFallback() {
        let clock = FakeClock()
        let fallback = RecordingFallback()
        let source = DefaultGPUProcessSource(
            registry: makeSource([[client(1, "Game", [5])]], clock: clock),
            fallback: fallback
        )

        let report = source.report(limit: 5)

        XCTAssertEqual(fallback.calls, 0)
        XCTAssertEqual(report.processes.map(\.pid), [1])
    }

    func testResetBaselineReachesRegistryAndFallback() {
        let clock = FakeClock()
        let fallback = RecordingFallback()
        let source = DefaultGPUProcessSource(registry: makeSource([[]], clock: clock), fallback: fallback)
        source.resetBaseline()
        XCTAssertEqual(fallback.resets, 1)
    }

    func testProcessUsageServiceDefaultsToTheRegistrySourceForGPU() {
        let clock = FakeClock()
        let registry = makeSource([[client(1, "Game", [5])]], clock: clock)
        let service = ProcessUsageService(
            gpuSource: DefaultGPUProcessSource(registry: registry, fallback: RecordingFallback())
        )
        XCTAssertEqual(service.report(sortedBy: .gpu, limit: 5).processes.map(\.pid), [1])
    }
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

    func testUtilizationFlowsIntoTheReportAndJSON() throws {
        let service = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [
            snapshot(gpu: GPUReport(utilizationPercent: 42)),
        ]))
        let report = service.read()

        XCTAssertEqual(report.gpu?.utilizationPercent, 42)
        XCTAssertFalse(report.notes.contains { $0.contains("GPU") })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(String(data: encoder.encode(report), encoding: .utf8))
        XCTAssertTrue(json.contains("\"gpu\":{\"utilization_percent\":42}"), json)
    }

    func testAbsentUtilizationOmitsTheFieldInsteadOfZero() throws {
        let service = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [snapshot(gpu: nil)]))
        let report = service.read()

        XCTAssertNil(report.gpu)
        XCTAssertTrue(report.notes.contains { $0.contains("GPU utilization unavailable") })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(String(data: encoder.encode(report), encoding: .utf8))
        XCTAssertFalse(json.contains("\"gpu\""), json)
    }

    func testReportDecodesWithoutGPUField() throws {
        let service = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [snapshot(gpu: nil)]))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SystemMetricsReport.self, from: encoder.encode(service.read()))
        XCTAssertNil(decoded.gpu)
    }

    func testHardwareSourceUsesInjectedUtilizationReader() {
        let source = HardwareSystemMetricsSource(gpu: FakeGPURegistry([], utilization: 12.5))
        XCTAssertEqual(source.readSnapshot().gpu?.utilizationPercent, 12.5)
        let none = HardwareSystemMetricsSource(gpu: FakeGPURegistry([], utilization: nil))
        XCTAssertNil(none.readSnapshot().gpu)
    }
}

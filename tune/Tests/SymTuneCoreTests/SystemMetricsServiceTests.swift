import XCTest
@testable import SymTuneCore

final class SystemMetricsServiceTests: XCTestCase {
    private func sample(
        _ timestamp: TimeInterval,
        cpu: [UInt64],
        network: UInt64 = 0
    ) -> SystemMetricsSnapshot {
        .init(
            timestamp: timestamp,
            cpu: .init(total: cpu, perCore: [cpu]),
            memory: .init(
                usedBytes: 1,
                freeBytes: 2,
                wiredBytes: 3,
                compressedBytes: 4,
                pressure: nil
            ),
            disk: .init(capacityBytes: 100, usedBytes: 40, freeBytes: 60),
            network: [.init(name: "en0", bytesIn: network, bytesOut: network)]
        )
    }

    func testDerivesUtilizationAndThroughput() {
        let source = FakeSystemMetricsSource(snapshots: [
            sample(1, cpu: [10, 10, 10, 70], network: 100),
            sample(3, cpu: [20, 20, 20, 80], network: 160)
        ])
        let service = SystemMetricsService(source: source)
        _ = service.read()
        let report = service.read()
        XCTAssertEqual(report.cpu.totalUtilization!, 0.75, accuracy: 0.0001)
        XCTAssertEqual(report.cpu.perCoreUtilization, [0.75])
        XCTAssertEqual(report.network.interfaces[0].bytesInPerSecond!, 30, accuracy: 0.0001)
    }

    func testCounterWraparound() {
        let source = FakeSystemMetricsSource(snapshots: [
            sample(1, cpu: [0, 0, 0, 0], network: UInt64.max - 9),
            sample(2, cpu: [0, 0, 0, 0], network: 10)
        ])
        let service = SystemMetricsService(source: source)
        _ = service.read()
        XCTAssertEqual(service.read().network.interfaces[0].bytesInPerSecond!, 20, accuracy: 0.0001)
    }

    func testNonPositiveTimeDoesNotDeriveRate() {
        let source = FakeSystemMetricsSource(snapshots: [
            sample(2, cpu: [0, 0, 0, 0], network: 1),
            sample(2, cpu: [0, 0, 0, 0], network: 2),
            sample(1, cpu: [0, 0, 0, 0], network: 3)
        ])
        let service = SystemMetricsService(source: source)
        _ = service.read()
        XCTAssertNil(service.read().network.interfaces[0].bytesInPerSecond)
        XCTAssertNil(service.read().network.interfaces[0].bytesInPerSecond)
    }

    func testUnavailableDegradesGracefully() {
        let report = SystemMetricsService(source: FakeSystemMetricsSource(snapshots: [.empty])).read()
        XCTAssertNil(report.cpu.totalUtilization)
        XCTAssertNil(report.memory.usedBytes)
        XCTAssertNil(report.disk)
        XCTAssertTrue(report.network.interfaces.isEmpty)
        XCTAssertFalse(report.notes.isEmpty)
    }
}

import XCTest
@testable import SymScopeCore

final class SnapshotServiceTests: XCTestCase {
    func testBuildAggregatesRealSubsystemState() async throws {
        let snapshot = await SnapshotService.build()

        // generatedAt is a valid ISO8601 timestamp close to "now" — proves the
        // formatter branch actually ran rather than returning a placeholder.
        let formatter = ISO8601DateFormatter()
        let generated = try XCTUnwrap(formatter.date(from: snapshot.generatedAt))
        XCTAssertLessThan(abs(generated.timeIntervalSinceNow), 10)

        // mcpServers mirrors what MCPDiscovery independently reports — proves the
        // snapshot is a real aggregation of the discovery service, not a stub.
        let (expectedServers, expectedServerNotes) = MCPDiscovery.discover()
        XCTAssertEqual(snapshot.mcpServers, expectedServers)
        for note in expectedServerNotes {
            XCTAssertTrue(snapshot.notes.contains(note))
        }

        // containers mirrors ContainerService's own report.
        let (expectedContainers, expectedContainerNotes) = await ContainerService.list()
        XCTAssertEqual(snapshot.containers.count, expectedContainers.count)
        for note in expectedContainerNotes {
            XCTAssertTrue(snapshot.notes.contains(note))
        }

        // ports come from a concurrent task that never throws in practice on a
        // healthy machine; either it succeeded (no "ports:" note) or it
        // degraded gracefully with a note instead of crashing the whole build.
        let hasPortsFailureNote = snapshot.notes.contains { $0.hasPrefix("ports:") }
        if !hasPortsFailureNote {
            XCTAssertTrue(snapshot.ports.allSatisfy { $0.port > 0 })
        }
    }

    func testBuildProducesFreshTimestampsAcrossCalls() async throws {
        let first = await SnapshotService.build()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let second = await SnapshotService.build()

        let formatter = ISO8601DateFormatter()
        let firstDate = try XCTUnwrap(formatter.date(from: first.generatedAt))
        let secondDate = try XCTUnwrap(formatter.date(from: second.generatedAt))
        XCTAssertGreaterThan(secondDate, firstDate)
    }
}

import XCTest
@testable import SymTuneCore

final class PowermetricsGPUProcessSourceTests: XCTestCase {

    func testUnprivilegedReportIsEmptyAndExplainsWhy() {
        let source = PowermetricsGPUProcessSource(isRunningAsRoot: { false })

        let report = source.report(limit: 5)

        XCTAssertEqual(report.sortedBy, .gpu)
        XCTAssertTrue(report.processes.isEmpty)
        XCTAssertTrue(report.notes.contains { $0.contains("root") })
    }

    // MARK: - plist parsing
    //
    // powermetrics's per-process plist schema is undocumented and has shifted
    // across macOS releases; these fixtures encode this parser's *assumption*
    // about the current shape (a top-level "tasks" array of dictionaries with
    // "name"/"pid"/"gputime_ms_per_s"). They prove the parser is internally
    // consistent, not that the assumption matches a real powermetrics binary
    // on every macOS version — that needs a hands-on check against the actual
    // tool, which this test suite cannot do (it would require root).

    func testParsesGPUTimeFromTheAssumedTasksSchema() throws {
        let plist: [String: Any] = [
            "tasks": [
                ["name": "renderer", "pid": 111, "gputime_ms_per_s": 250.0],
                ["name": "idle-app", "pid": 222, "gputime_ms_per_s": 0.0],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let processes = try XCTUnwrap(PowermetricsGPUProcessSource.parseProcessGPU(plistData: data))

        XCTAssertEqual(processes.count, 2)
        let renderer = try XCTUnwrap(processes.first { $0.pid == 111 })
        XCTAssertEqual(renderer.name, "renderer")
        // 250 ms of GPU time per second of wall clock = 25% of one GPU's worth of time.
        XCTAssertEqual(try XCTUnwrap(renderer.gpuPercent), 25, accuracy: 0.001)
    }

    func testHandlesTheNULTerminatorPowermetricsAppendsAfterEachSample() throws {
        let plist: [String: Any] = ["tasks": [["name": "worker", "pid": 7, "gputime_ms_per_s": 10.0]]]
        var data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        data.append(0) // the NUL separator powermetrics writes between samples

        let processes = try XCTUnwrap(PowermetricsGPUProcessSource.parseProcessGPU(plistData: data))

        XCTAssertEqual(processes.first?.name, "worker")
    }

    func testUnrecognizedSchemaReturnsNilRatherThanFabricatingData() throws {
        let plist: [String: Any] = ["something_else": ["unexpected": true]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertNil(PowermetricsGPUProcessSource.parseProcessGPU(plistData: data))
    }

    func testNotAPlistReturnsNilRatherThanCrashing() {
        let data = Data("not a plist".utf8)

        XCTAssertNil(PowermetricsGPUProcessSource.parseProcessGPU(plistData: data))
    }
}

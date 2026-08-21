import XCTest
@testable import SymTuneCore

/// The read surface the CLI and the MCP server call: process listings and the
/// extended-brightness status. Both are thin facades, which is exactly why they
/// shipped untested — a wrong unit or a dropped sort argument here is invisible
/// to the layers below, which have their own tests.
final class TuneControllerProcessBrightnessTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symtune-proc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Controller with a scripted process table and no hardware writes.
    private func makeController(_ source: FakeProcessSampleSource) -> TuneController {
        TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            dataDir: tmpDir,
            processSource: source
        )
    }

    /// Two sweeps one second apart: `busy` burns half a core, `idle` burns none.
    private func twoSweeps() -> FakeProcessSampleSource {
        FakeProcessSampleSource([
            ProcessSampleSet(
                timestamp: 1_000,
                samples: [
                    fakeProcessSample(pid: 11, name: "busy", cpuNanoseconds: 0, memoryMB: 10),
                    fakeProcessSample(pid: 22, name: "hungry", cpuNanoseconds: 0, memoryMB: 900),
                ],
                unreadableCount: 3
            ),
            ProcessSampleSet(
                timestamp: 1_001,
                samples: [
                    fakeProcessSample(pid: 11, name: "busy", cpuNanoseconds: 500_000_000, memoryMB: 10),
                    fakeProcessSample(pid: 22, name: "hungry", cpuNanoseconds: 0, memoryMB: 900),
                ],
                unreadableCount: 3
            ),
        ])
    }

    // MARK: - topProcesses

    func testTopProcessesRanksByCPUOnTheSecondSweep() throws {
        let controller = makeController(twoSweeps())

        // First call establishes the CPU baseline; only memory is ranked.
        let first = controller.topProcesses(sortedBy: .cpu, limit: 5)
        XCTAssertTrue(first.processes.allSatisfy { $0.cpuPercent == nil })

        let second = controller.topProcesses(sortedBy: .cpu, limit: 5)
        XCTAssertEqual(second.sortedBy, .cpu)
        XCTAssertEqual(second.processes.first?.name, "busy", "0.5s of CPU over 1s outranks an idle process")
        XCTAssertEqual(try XCTUnwrap(second.processes.first?.cpuPercent), 50, accuracy: 0.001)
        XCTAssertEqual(second.unreadableProcessCount, 3, "root-owned processes stay visible as a count")
    }

    func testTopProcessesRanksByMemoryWhenAsked() {
        let controller = makeController(twoSweeps())

        let report = controller.topProcesses(sortedBy: .memory, limit: 5)

        XCTAssertEqual(report.sortedBy, .memory)
        XCTAssertEqual(report.processes.map(\.name), ["hungry", "busy"])
    }

    func testTopProcessesHonoursTheLimit() {
        let controller = makeController(twoSweeps())

        XCTAssertEqual(controller.topProcesses(sortedBy: .memory, limit: 1).processes.count, 1)
        XCTAssertEqual(
            controller.topProcesses(sortedBy: .memory, limit: 5).sampledProcessCount, 2,
            "the sampled count reflects the sweep, not the limit"
        )
    }

    /// Without this, the first reading after the popover reopens would average
    /// CPU across the whole time the card was closed.
    func testResetProcessBaselineDropsTheCPUDelta() {
        let controller = makeController(twoSweeps())
        _ = controller.topProcesses(sortedBy: .cpu, limit: 5)

        controller.resetProcessBaseline()

        let afterReset = controller.topProcesses(sortedBy: .cpu, limit: 5)
        XCTAssertTrue(
            afterReset.processes.allSatisfy { $0.cpuPercent == nil },
            "a dropped baseline means no CPU rate until the next sweep"
        )
    }

    // MARK: - extendedBrightnessStatus

    /// Neutral means neutral: nothing requested, nothing applied, no mode — and
    /// crucially not "waiting for HDR", which would put a warning in the UI for
    /// a user who never touched the slider.
    func testExtendedBrightnessStatusIsNeutralWhenNothingWasApplied() {
        let controller = makeController(twoSweeps())

        let status = controller.extendedBrightnessStatus()

        XCTAssertNil(status.requested)
        XCTAssertNil(status.effective)
        XCTAssertNil(status.mode)
        XCTAssertFalse(status.isWaitingForEDR)
        // `isSupported` and `availableHeadroom` depend on the host's display, so
        // only their consistency is asserted: a host that reports headroom must
        // report it as a number at or above the SDR reference.
        if let headroom = status.availableHeadroom {
            XCTAssertGreaterThanOrEqual(headroom, 1.0)
        }
    }

    func testReassertDisplayOverridesIsSafeWithNoOverrides() {
        let controller = makeController(twoSweeps())

        // Must not throw or change anything when nothing is overridden — it runs
        // on every wake, including wakes where the user never touched a slider.
        controller.reassertDisplayOverrides()

        XCTAssertNil(controller.extendedBrightnessStatus().requested)
        XCTAssertNil(controller.activeOverrides().edrBrightness)
    }
}

// MARK: - ExtendedBrightnessStatus

final class ExtendedBrightnessStatusTests: XCTestCase {

    func testWaitingForEDRIsTrueOnlyWhileNoExtendedRangeBoostIsInEffect() {
        let requestedButNotEngaged = ExtendedBrightnessStatus(
            requested: 1.4, effective: nil, mode: nil, availableHeadroom: 1.0, isSupported: true
        )
        XCTAssertTrue(requestedButNotEngaged.isWaitingForEDR)

        // A software lift is applied, but it is not the real thing — the UI must
        // still tell the user HDR has not engaged.
        let softwareLift = ExtendedBrightnessStatus(
            requested: 1.4, effective: 1.15, mode: .softwareLift, availableHeadroom: 1.0, isSupported: true
        )
        XCTAssertTrue(softwareLift.isWaitingForEDR)

        let engaged = ExtendedBrightnessStatus(
            requested: 1.4, effective: 1.4, mode: .extendedRange, availableHeadroom: 1.6, isSupported: true
        )
        XCTAssertFalse(engaged.isWaitingForEDR)

        let neutral = ExtendedBrightnessStatus(
            requested: nil, effective: nil, mode: nil, availableHeadroom: 1.0, isSupported: true
        )
        XCTAssertFalse(neutral.isWaitingForEDR, "an untouched slider is not 'waiting'")
    }

    func testStatusRoundTripsThroughJSONForTheAgentSurface() throws {
        let status = ExtendedBrightnessStatus(
            requested: 1.45, effective: 1.2, mode: .extendedRange, availableHeadroom: 12.5, isSupported: true
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(status)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // The MCP/CLI contract is snake_case; a camelCase key would silently
        // break agents reading the field.
        XCTAssertTrue(json.contains("\"available_headroom\""), json)
        XCTAssertTrue(json.contains("\"extendedRange\""), "the mode is a stable raw value")
    }
}

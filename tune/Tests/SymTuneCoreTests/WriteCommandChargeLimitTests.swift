import XCTest
@testable import SymTuneCore

// MARK: - WriteCommand charge-limit integer conversion (issue #285)
//
// The shared `WriteCommand.apply` interface hands every descriptor a `Double`.
// The integer-typed charge-limit command is parsed as `Int` first (CLI
// `parseInt`, MCP `requireInt`), widened to `Double`, and converted back
// inside the descriptor. `Double(Int.max)` rounds up to exactly 2^63, so the
// trapping `Int(_:)` initializer aborts the whole process — SIGTRAP killed
// both the CLI and the MCP server (issue #285).
//
// Contract under test:
//   * Unrepresentable values throw `TuneError.usage` before any controller or
//     hardware access — no SMC write, no history event.
//   * Representable values keep flowing through the documented
//     `SafetyPolicy` clamping (50–100), including finite out-of-range input.
//
// All hardware access goes through the injected fakes; no real SMC, battery,
// display, or sudo is ever involved.
final class WriteCommandChargeLimitTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writecmd-charge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dataDir {
            try? FileManager.default.removeItem(at: dataDir)
        }
    }

    /// Controller wired entirely to fakes: the fake SMC connection records
    /// every write, the fake battery reports AC power, and history/profile
    /// state lives in the per-test temp directory.
    private func makeController() -> (controller: TuneController, connection: FakeSMCConnection) {
        let connection = FakeSMCConnection(isOpen: true, keys: [
            "CHTE": FakeSMCKeyResult(dataType: smcEncodeKey("ui32"), bytes: [0, 0, 0, 0]),
        ])
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: connection),
            batterySource: FakeBatterySource(
                result: .success(BatteryProperties(externalConnected: true))
            ),
            dataDir: dataDir
        )
        return (controller, connection)
    }

    private func batteryLimitSetCommand() throws -> WriteCommand {
        try XCTUnwrap(WriteCommand.forCLIPrefix("battery-limit set"))
    }

    // MARK: - Descriptor lookup

    func testDescriptorLookupResolvesBothSurfaces() throws {
        let cliCommand = try batteryLimitSetCommand()
        XCTAssertEqual(cliCommand.mcpName, "set_charge_limit")
        guard case .integer = cliCommand.valueType else {
            return XCTFail("battery-limit set must be an integer-typed command")
        }

        let mcpCommand = try XCTUnwrap(WriteCommand.forMCPName("set_charge_limit"))
        XCTAssertEqual(mcpCommand.name, "battery-limit.set")
        XCTAssertEqual(mcpCommand.cliPrefix, "battery-limit set")
    }

    // MARK: - Rejected inputs (must never reach hardware)

    func testIntMaxEdgeDoubleThrowsUsageErrorBeforeAnyHardwareAccess() throws {
        let command = try batteryLimitSetCommand()
        let (controller, connection) = makeController()

        // Original input from issue #285: `Int("9223372036854775807")`
        // succeeds as Int.max, then `Double(Int.max)` rounds to 2^63 — no
        // longer representable as Int.
        XCTAssertThrowsError(try command.apply(controller, Double(Int.max))) { error in
            guard case TuneError.usage(_) = error else {
                return XCTFail("expected TuneError.usage, got \(error)")
            }
            XCTAssertEqual((error as? TuneError)?.exitCode, 2)
        }

        XCTAssertTrue(connection.writtenKeys.isEmpty,
                      "a rejected percent must not write to the SMC")
        XCTAssertTrue(controller.getHistory().isEmpty,
                      "a rejected percent must not log a history event")
    }

    func testNonFiniteDoublesThrowUsageError() throws {
        let command = try batteryLimitSetCommand()
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            let (controller, connection) = makeController()
            XCTAssertThrowsError(try command.apply(controller, value),
                                 "value \(value) must be rejected") { error in
                guard case TuneError.usage(_) = error else {
                    return XCTFail("expected TuneError.usage for \(value), got \(error)")
                }
            }
            XCTAssertTrue(connection.writtenKeys.isEmpty,
                          "no SMC write for non-finite \(value)")
            XCTAssertTrue(controller.getHistory().isEmpty,
                          "no history event for non-finite \(value)")
        }
    }

    // MARK: - Accepted inputs (mocked hardware, documented clamping)

    func testValidPercentAppliesThroughMockedHardware() throws {
        let command = try batteryLimitSetCommand()
        let (controller, connection) = makeController()

        XCTAssertNoThrow(try command.apply(controller, 80))

        let event = controller.getHistory().last
        XCTAssertEqual(event?.action, "battery-limit.set")
        XCTAssertEqual(event?.requestedValue, 80)
        XCTAssertEqual(event?.clampedValue, 80)
        XCTAssertEqual(event?.appliedValue, 80)
        XCTAssertEqual(event?.result, "success")

        XCTAssertEqual(connection.writtenKeys.first?.key, "CHTE",
                       "the write must land on the injected fake connection")
        XCTAssertEqual(controller.statusReport().activeOverrides.chargeLimitPercent, 80)
    }

    func testNeighborBoundariesKeepDocumentedClamping() throws {
        let command = try batteryLimitSetCommand()
        let cases: [(input: Double, clamped: Double)] = [
            (49, 50),   // just below the minimum → clamp up
            (101, 100), // just above the maximum → clamp down
            (50, 50),   // exact minimum stays
            (100, 100), // exact maximum stays
        ]

        for testCase in cases {
            let (controller, _) = makeController()
            XCTAssertNoThrow(try command.apply(controller, testCase.input),
                             "input \(testCase.input) must be accepted")

            let event = controller.getHistory().last
            XCTAssertEqual(event?.action, "battery-limit.set")
            XCTAssertEqual(event?.requestedValue, testCase.input)
            XCTAssertEqual(event?.clampedValue, testCase.clamped,
                           "input \(testCase.input) must clamp to \(testCase.clamped)")
            XCTAssertEqual(event?.appliedValue, testCase.clamped)
            XCTAssertEqual(event?.result, "success")
            XCTAssertEqual(controller.statusReport().activeOverrides.chargeLimitPercent,
                           Int(testCase.clamped))
        }
    }

    func testRepresentableDomainEdgeStillClampsInsteadOfTrapping() throws {
        let command = try batteryLimitSetCommand()
        let (controller, _) = makeController()

        // `Double(Int.min)` is exactly −2^63: representable as Int, so it
        // takes the clamping path rather than the rejection path.
        XCTAssertNoThrow(try command.apply(controller, Double(Int.min)))

        let event = controller.getHistory().last
        XCTAssertEqual(event?.action, "battery-limit.set")
        XCTAssertEqual(event?.requestedValue, Double(Int.min))
        XCTAssertEqual(event?.clampedValue, 50)
        XCTAssertEqual(event?.appliedValue, 50)
        XCTAssertEqual(event?.result, "success")
    }

    func testLargeRepresentableFiniteValueStillClamps() throws {
        let command = try batteryLimitSetCommand()
        let (controller, _) = makeController()

        // 2^53 is finite and exactly representable as Int but far outside
        // 50–100: the documented clamping contract applies.
        let huge = 9_007_199_254_740_992.0
        XCTAssertNoThrow(try command.apply(controller, huge))

        let event = controller.getHistory().last
        XCTAssertEqual(event?.action, "battery-limit.set")
        XCTAssertEqual(event?.requestedValue, huge)
        XCTAssertEqual(event?.clampedValue, 100)
        XCTAssertEqual(event?.appliedValue, 100)
        XCTAssertEqual(event?.result, "success")
    }
}

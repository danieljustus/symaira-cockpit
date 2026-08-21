import XCTest
import SymairaMCP
@testable import SymTuneMCP
@testable import SymTuneCore

/// Issue #288: the MCP `keep_awake` tool must bound `duration_seconds` to the
/// CLI's 24-hour contract — finite, non-negative, ≤ 86400 — both in the JSON
/// schema advertised by `tools/list` and at runtime in the tool invocation
/// path.
final class KeepAwakeDurationBoundsTests: XCTestCase {

    // MARK: - Schema bounds (tools/list over the wire)

    func testKeepAwakeDurationSchemaCarriesBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "keep_awake" })
        let prop = try XCTUnwrap(tool.inputSchema.properties["duration_seconds"])
        XCTAssertEqual(prop.type, "number")
        XCTAssertEqual(prop.minimum, 0)
        XCTAssertEqual(prop.maximum, 86_400)
    }

    // MARK: - Accepted boundary values (tools/call over the wire)

    func testKeepAwakeAcceptsZeroDuration() async throws {
        try await assertKeepAwakeAccepted(durationSeconds: 0)
    }

    func testKeepAwakeAcceptsMaxDuration() async throws {
        try await assertKeepAwakeAccepted(durationSeconds: 86_400)
    }

    func testKeepAwakeAcceptsMidRangeDuration() async throws {
        try await assertKeepAwakeAccepted(durationSeconds: 3_600)
    }

    // MARK: - Rejected values

    func testKeepAwakeRejectsNegativeDurationOverTheWire() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let (envelope, _) = try await mcpCallTool(
            harness,
            name: "keep_awake",
            arguments: ["enabled": true, "duration_seconds": -5.0]
        )
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertTrue(envelope.error?.message.contains("duration_seconds") == true)
        XCTAssertTrue(envelope.error?.message.contains("non-negative") == true)
    }

    func testKeepAwakeRejectsOversizedDurationOverTheWire() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let (envelope, _) = try await mcpCallTool(
            harness,
            name: "keep_awake",
            arguments: ["enabled": true, "duration_seconds": 86_401.0]
        )
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertTrue(envelope.error?.message.contains("duration_seconds") == true)
        XCTAssertTrue(envelope.error?.message.contains("86400") == true)
    }

    /// Non-finite values cannot cross JSON-RPC over the wire (JSON has no
    /// NaN/Infinity literal), so they are exercised directly against the MCP
    /// tool's invocation path — the exact code that guards the controller.
    func testKeepAwakeRejectsNonFiniteDurations() throws {
        let controller = TuneController()
        for duration in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertThrowsError(
                try KeepAwakeTool().invoke(
                    arguments: [
                        "enabled": .bool(true),
                        "duration_seconds": .number(duration),
                    ],
                    controller: controller
                )
            ) { error in
                guard case TuneError.usage(let message) = error else {
                    return XCTFail("Expected .usage, got \(error)")
                }
                XCTAssertTrue(message.contains("finite"), message)
            }
        }
    }

    // MARK: - Helpers

    private func assertKeepAwakeAccepted(durationSeconds: Double) async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (enableEnvelope, enableResult) = try await mcpCallTool(
            harness,
            name: "keep_awake",
            arguments: ["enabled": true, "duration_seconds": durationSeconds]
        )
        XCTAssertNil(enableEnvelope.error)
        XCTAssertEqual(enableResult?.isError, false)

        let (disableEnvelope, disableResult) = try await mcpCallTool(
            harness,
            name: "keep_awake",
            arguments: ["enabled": false]
        )
        XCTAssertNil(disableEnvelope.error)
        XCTAssertEqual(disableResult?.isError, false)
    }
}

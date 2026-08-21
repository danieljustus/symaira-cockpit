import XCTest
import SymairaMCP
@testable import SymTuneMCP
@testable import SymTuneCore

// MARK: - Shared test harness

/// Reads one newline-delimited line from a handle. Test-local only: a single
/// iterator is created per handle so reads never interleave.
final class LineReader: @unchecked Sendable {
    private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(handle: FileHandle) {
        iterator = handle.bytes.lines.makeAsyncIterator()
    }

    func nextLine() async throws -> String? {
        try await iterator.next()
    }
}

/// Boots a `TuneMCPServer` on an in-process pipe pair and returns a harness
/// that lets the test act as the MCP client.
struct MCPTestHarness {
    let server: MCPServer
    let clientWrite: FileHandle
    let reader: LineReader
    let serverTask: Task<Void, Error>

    static func make(controller: TuneController = TuneController(), config: TuneConfig = TuneConfig()) throws -> MCPTestHarness {
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let transport = MCPStdioTransport(
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let tuneServer = TuneMCPServer(controller: controller, config: config)
        let server = tuneServer.makeServer()
        // Detached: async XCTest methods run on a special executor that never
        // schedules unstructured tasks created inside the test body.
        let serverTask = Task.detached { try await server.start(transport: transport) }
        return MCPTestHarness(
            server: server,
            clientWrite: clientToServer.fileHandleForWriting,
            reader: LineReader(handle: serverToClient.fileHandleForReading),
            serverTask: serverTask
        )
    }
}

struct MCPTestEnvelope: Decodable {
    let jsonrpc: String?
    let id: MCPJSONRPCID?
    let result: MCPJSONValue?
    let error: MCPJSONRPCErrorObject?
}

enum MCPTestTimeout: Error {
    case waitingForResponse
}

func mcpSend(_ line: String, to handle: FileHandle) throws {
    var data = Data(line.utf8)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

/// Reads the next response line, failing the test after a 10s timeout
/// instead of hanging the suite if the server misbehaves.
func mcpNextLine(_ reader: LineReader) async throws -> String {
    try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask { try await reader.nextLine() }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return nil
        }
        guard let first = try await group.next() else {
            throw MCPTestTimeout.waitingForResponse
        }
        group.cancelAll()
        if let line = first {
            return line
        }
        throw MCPTestTimeout.waitingForResponse
    }
}

func mcpDecodeEnvelope(_ line: String) throws -> MCPTestEnvelope {
    try JSONDecoder().decode(MCPTestEnvelope.self, from: Data(line.utf8))
}

func mcpDecodeResult<T: Decodable>(_ envelope: MCPTestEnvelope, as type: T.Type) throws -> T? {
    guard let result = envelope.result else { return nil }
    let data = try JSONEncoder().encode(result)
    return try JSONDecoder().decode(type, from: data)
}

/// Sends a `tools/list` request and returns the parsed result.
func mcpListTools(_ harness: MCPTestHarness) async throws -> MCPListToolsResult {
    try mcpSend(#"{"jsonrpc":"2.0","id":100,"method":"tools/list"}"#, to: harness.clientWrite)
    let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
    return try XCTUnwrap(try mcpDecodeResult(envelope, as: MCPListToolsResult.self))
}

/// Sends a `tools/call` request and returns the parsed result.
func mcpCallTool(_ harness: MCPTestHarness, name: String, arguments: [String: Any] = [:]) async throws -> (MCPTestEnvelope, MCPCallToolResult?) {
    let argsJSON = String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8) ?? "{}"
    let line = #"{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(argsJSON)}}"#
    try mcpSend(line, to: harness.clientWrite)
    let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
    return (envelope, try mcpDecodeResult(envelope, as: MCPCallToolResult.self))
}

// MARK: - Tool schema bounds

final class MCPServerToolSchemaTests: XCTestCase {

    private func valueBounds(in schema: MCPJSONSchema, for property: String) -> (minimum: Double, maximum: Double)? {
        guard let prop = schema.properties[property] else { return nil }
        return (prop.minimum ?? 0, prop.maximum ?? 0)
    }

    func testSetBrightnessSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_brightness" })
        XCTAssertEqual(tool.inputSchema.required, ["value"])
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.minimum, 0.0)
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.maximum, 1.0)
    }

    func testSetExtendedBrightnessSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_extended_brightness" })
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.minimum, SafetyPolicy.extendedBrightnessMin)
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.maximum, SafetyPolicy.extendedBrightnessMax)
    }

    func testSetDimSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_dim" })
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.minimum, SafetyPolicy.dimMin)
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.maximum, SafetyPolicy.dimMax)
    }

    func testSetWarmthSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_warmth" })
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.minimum, 0.0)
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "value")?.maximum, 1.0)
    }

    func testSetFanSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_fan" })
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "fraction")?.minimum, SafetyPolicy.fanFractionMin)
        XCTAssertEqual(valueBounds(in: tool.inputSchema, for: "fraction")?.maximum, SafetyPolicy.fanFractionMax)
    }

    func testSetChargeLimitSchemaBounds() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "set_charge_limit" })
        let prop = try XCTUnwrap(tool.inputSchema.properties["percent"])
        XCTAssertEqual(prop.type, "integer")
        XCTAssertEqual(prop.minimum, Double(SafetyPolicy.chargeLimitMin))
        XCTAssertEqual(prop.maximum, Double(SafetyPolicy.chargeLimitMax))
    }

    func testEmptySchemaNormalizedToEmptyObject() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let tool = try XCTUnwrap(tools.tools.first { $0.name == "get_ai_usage" })
        XCTAssertEqual(tool.inputSchema.type, "object")
        XCTAssertTrue(tool.inputSchema.properties.isEmpty)
        XCTAssertTrue(tool.inputSchema.required.isEmpty)
    }

    func testToolListCarriesSafetyBoundsOverTheWire() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }
        let tools = try await mcpListTools(harness)
        let names = tools.tools.map(\.name)
        // The full tool set is unchanged by the migration.
        for expected in [
            "get_capabilities", "get_sensors", "get_battery", "list_displays",
            "get_system_metrics", "get_top_processes", "get_ai_usage",
            "keep_awake", "keep_awake_status",
            "get_brightness", "save_profile", "load_profile", "list_profiles",
            "delete_profile", "get_status", "get_history", "set_brightness",
            "set_extended_brightness", "set_dim", "reset_dim", "set_warmth",
            "reset_warmth", "restore", "set_fan", "set_charge_limit", "clear_charge_limit",
        ] {
            XCTAssertTrue(names.contains(expected), "missing tool \(expected)")
        }
    }
}

// MARK: - MCPTool dispatch (tools/call)

final class MCPServerToolCallTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-mcp-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testReadOnlyModeHidesWriteToolsAndRejectsCall() async throws {
        let config = TuneConfig(mcpMode: "read-only")
        let harness = try MCPTestHarness.make(controller: TuneController(), config: config)
        defer { try? harness.clientWrite.close() }

        let tools = try await mcpListTools(harness)
        let names = tools.tools.map(\.name)
        XCTAssertTrue(names.contains("get_capabilities"))
        XCTAssertTrue(names.contains("get_brightness"))
        XCTAssertFalse(names.contains("set_brightness"))
        XCTAssertFalse(names.contains("set_fan"))
        XCTAssertFalse(names.contains("keep_awake"))

        let (envelope, _) = try await mcpCallTool(harness, name: "set_brightness", arguments: ["value": 0.5])
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
    }

    func testCallToolReturnsContentArray() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_capabilities")
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)
        XCTAssertEqual(result?.content.count, 1)
        XCTAssertEqual(result?.content.first?.type, "text")
    }

    func testCallToolUnknownToolReturnsError() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, _) = try await mcpCallTool(harness, name: "nonexistent_tool")
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertTrue(envelope.error?.message.contains("Unknown tool") == true)
    }

    func testCallGetCapabilities() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (_, result) = try await mcpCallTool(harness, name: "get_capabilities")
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("symtune"))
    }

    func testCallGetSensors() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_sensors")
        XCTAssertNil(envelope.error)
        XCTAssertNotNil(result?.content.first?.text)
    }

    func testCallGetBattery() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_battery")
        XCTAssertNil(envelope.error)
        XCTAssertNotNil(result?.content.first?.text)
    }

    func testCallGetStatus() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (_, result) = try await mcpCallTool(harness, name: "get_status")
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("health_score"))
    }

    func testCallGetHistory() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_history")
        XCTAssertNil(envelope.error)
        XCTAssertNotNil(result?.content.first?.text)
    }

    func testCallListDisplays() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "list_displays")
        XCTAssertNil(envelope.error)
        XCTAssertNotNil(result?.content.first?.text)
    }

    func testCallGetSystemMetrics() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (_, result) = try await mcpCallTool(harness, name: "get_system_metrics")
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("cpu"))
        XCTAssertTrue(text.contains("memory"))
        XCTAssertTrue(text.contains("network"))
    }

    /// The process listing is the agent-facing answer to "what is making this
    /// Mac slow?", so its ranking key and its snake_case shape are contract.
    func testCallGetTopProcessesRanksByMemoryWhenAsked() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(
            harness, name: "get_top_processes", arguments: ["sort_by": "memory", "limit": 3]
        )

        XCTAssertNil(envelope.error)
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"sorted_by\":\"memory\""), text.prefix(200).description)
        XCTAssertTrue(text.contains("memory_bytes"), text.prefix(200).description)
        XCTAssertTrue(text.contains("unreadable_process_count"), text.prefix(200).description)
    }

    /// An unknown ranking key must fail loudly rather than silently falling back
    /// to CPU — an agent asking for the wrong thing should be told.
    func testCallGetTopProcessesRejectsAnUnknownSortKey() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, _) = try await mcpCallTool(
            harness, name: "get_top_processes", arguments: ["sort_by": "disk"]
        )

        XCTAssertNotNil(envelope.error, "an invalid sort_by must surface as an error")
    }

    func testCallGetAIUsageListsProviders() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_ai_usage")
        XCTAssertNil(envelope.error)
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("openrouter"))
        XCTAssertEqual(result?.isError, false)
    }

    func testGetAIUsageToolIsReadOnly() async throws {
        let config = TuneConfig(mcpMode: "read-only")
        let harness = try MCPTestHarness.make(controller: TuneController(), config: config)
        defer { try? harness.clientWrite.close() }

        let tools = try await mcpListTools(harness)
        let names = tools.tools.map(\.name)
        XCTAssertTrue(names.contains("get_ai_usage"), "read-only tool must stay in read-only mode")
        XCTAssertFalse(names.contains("set_fan"))
    }

    func testCallSetDim() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "set_dim", arguments: ["value": 0.5])
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)
    }

    func testCallResetDim() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "reset_dim")
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)
    }

    func testCallRestore() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "restore")
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)
    }

    func testCallKeepAwakeTool() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (enableEnvelope, enableResult) = try await mcpCallTool(
            harness,
            name: "keep_awake",
            arguments: ["enabled": true, "prevent_display_sleep": true]
        )
        XCTAssertNil(enableEnvelope.error)
        XCTAssertEqual(enableResult?.isError, false)

        let (disableEnvelope, disableResult) = try await mcpCallTool(harness, name: "keep_awake", arguments: ["enabled": false])
        XCTAssertNil(disableEnvelope.error)
        XCTAssertEqual(disableResult?.isError, false)
    }

    func testCallGetBrightnessTool() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "get_brightness")
        if envelope.error != nil {
            // On hosts without a controllable display the honest error is fine.
            XCTAssertTrue(
                envelope.error?.message.contains("unsupported") == true
                    || envelope.error?.message.contains("display") == true
                    || envelope.error?.message.contains("failed") == true,
                "unexpected error: \(envelope.error?.message ?? "")"
            )
        } else {
            XCTAssertEqual(result?.isError, false)
        }
    }

    func testCallSetBrightnessTool() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "set_brightness", arguments: ["value": 0.75])
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)
    }

    func testCallSetExtendedBrightnessTool() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "set_extended_brightness", arguments: ["value": 1.2])
        if envelope.error != nil {
            XCTAssertFalse(envelope.error?.message.isEmpty == true)
        } else {
            XCTAssertEqual(result?.isError, false)
        }
    }

    func testCallSetWarmthAndResetWarmthTools() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (warmthEnvelope, warmthResult) = try await mcpCallTool(harness, name: "set_warmth", arguments: ["value": 0.4])
        if warmthEnvelope.error != nil {
            XCTAssertTrue(
                warmthEnvelope.error?.message.contains("unsupported") == true
                    || warmthEnvelope.error?.message.contains("display") == true
                    || warmthEnvelope.error?.message.contains("failed") == true,
                "unexpected error: \(warmthEnvelope.error?.message ?? "")"
            )
        } else {
            XCTAssertEqual(warmthResult?.isError, false)
        }

        let (resetEnvelope, resetResult) = try await mcpCallTool(harness, name: "reset_warmth")
        if resetEnvelope.error != nil {
            XCTAssertTrue(
                resetEnvelope.error?.message.contains("unsupported") == true
                    || resetEnvelope.error?.message.contains("display") == true
                    || resetEnvelope.error?.message.contains("failed") == true,
                "unexpected error: \(resetEnvelope.error?.message ?? "")"
            )
        } else {
            XCTAssertEqual(resetResult?.isError, false)
        }
    }

    func testCallProfileTools() async throws {
        let mockDisplay = MockMCPDisplayWriteService()
        let controller = TuneController(displayWrite: mockDisplay, dataDir: tmpDir)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        // Missing name is an honest usage error.
        let (noNameEnvelope, _) = try await mcpCallTool(harness, name: "save_profile")
        XCTAssertNotNil(noNameEnvelope.error)

        let (saveEnvelope, saveResult) = try await mcpCallTool(harness, name: "save_profile", arguments: ["name": "reading_mode"])
        XCTAssertNil(saveEnvelope.error)
        XCTAssertEqual(saveResult?.isError, false)

        let (listEnvelope, listResult) = try await mcpCallTool(harness, name: "list_profiles")
        XCTAssertNil(listEnvelope.error)
        XCTAssertTrue(listResult?.content.first?.text.contains("reading_mode") == true)

        let (loadEnvelope, loadResult) = try await mcpCallTool(harness, name: "load_profile", arguments: ["name": "reading_mode"])
        XCTAssertNil(loadEnvelope.error)
        XCTAssertEqual(loadResult?.isError, false)

        let (deleteEnvelope, deleteResult) = try await mcpCallTool(harness, name: "delete_profile", arguments: ["name": "reading_mode"])
        XCTAssertNil(deleteEnvelope.error)
        XCTAssertEqual(deleteResult?.isError, false)
    }

    func testCallSetFanRequiresSMCOrRoot() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, _) = try await mcpCallTool(harness, name: "set_fan", arguments: ["fraction": 0.5])
        XCTAssertNotNil(envelope.error)
        let message = envelope.error?.message ?? ""
        XCTAssertTrue(
            message.contains("SMC") || message.contains("root") || message.contains("permission") || message.contains("unsupported"),
            "unexpected error: \(message)"
        )
    }

    func testCallSetChargeLimitRequiresSMCOrRoot() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        let (envelope, _) = try await mcpCallTool(harness, name: "set_charge_limit", arguments: ["percent": 80])
        XCTAssertNotNil(envelope.error)
        let message = envelope.error?.message ?? ""
        XCTAssertTrue(
            message.contains("SMC") || message.contains("root") || message.contains("permission") || message.contains("unsupported"),
            "unexpected error: \(message)"
        )
    }

    func testCallSetFanSuccess() async throws {
        let connection = MockSMCConnection()
        let smcService = SMCService(connection: connection)
        let batterySource = MockBatterySource()
        let controller = TuneController(smcService: smcService, batterySource: batterySource)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "set_fan", arguments: ["fraction": 0.5])
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)

        // Verify something was written to SMC connection
        XCTAssertFalse(connection.writtenKeys.isEmpty)
    }

    func testCallSetChargeLimitSuccess() async throws {
        let connection = MockSMCConnection()
        let smcService = SMCService(connection: connection)
        let batterySource = MockBatterySource()
        let controller = TuneController(smcService: smcService, batterySource: batterySource)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "set_charge_limit", arguments: ["percent": 80])
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)

        // Verify something was written to SMC connection
        XCTAssertFalse(connection.writtenKeys.isEmpty)
    }

    func testCallClearChargeLimitSuccess() async throws {
        let connection = MockSMCConnection()
        let smcService = SMCService(connection: connection)
        let batterySource = MockBatterySource()
        let controller = TuneController(smcService: smcService, batterySource: batterySource)
        let harness = try MCPTestHarness.make(controller: controller)
        defer { try? harness.clientWrite.close() }

        let (envelope, result) = try await mcpCallTool(harness, name: "clear_charge_limit")
        XCTAssertNil(envelope.error)
        XCTAssertEqual(result?.isError, false)

        // Verify something was written to SMC connection
        XCTAssertFalse(connection.writtenKeys.isEmpty)
    }
}

// MARK: - Test doubles

final class MockMCPDisplayWriteService: DisplayWriteServiceProtocol, @unchecked Sendable {
    var brightness: Double = 0.8
    func getBuiltinBrightness() throws -> Double { brightness }
    func setBuiltinBrightness(_ value: Float) throws { brightness = Double(value) }
    func applyWarmth(_ warmth: Float) throws {}
    func resetWarmth() throws {}
    func applyExtendedBrightness(_ multiplier: Double, displayID: UInt32?) throws {}
}

final class MockBatterySource: BatterySource {
    func readProperties() -> BatterySourceResult {
        return .success(BatteryProperties(externalConnected: true))
    }
}

struct MockSMCWrittenKey {
    let key: String
    let dataType: UInt32
    let bytes: [UInt8]
}

final class MockSMCConnection: SMCConnectionProtocol, @unchecked Sendable {
    var isOpen: Bool = true
    var keys: [String: (UInt32, [UInt8])] = [:]
    var writtenKeys: [MockSMCWrittenKey] = []

    init() {
        // FNum: 1 fan
        keys["FNum"] = (smcEncodeKey("ui8 "), [1])
        #if arch(arm64)
        // Apple Silicon uses flt for target / min / max RPM
        keys["F0Mx"] = encodeFlt(6000.0)
        keys["F0Mn"] = encodeFlt(1200.0)
        keys["F0Md"] = encodeUi8(1)
        keys["CHTE"] = encodeUi32(0) // non-nil for detection
        keys["CH0B"] = encodeUi8(0) // non-nil for detection
        #else
        // Intel uses fpe2 / ui16
        keys["F0Mx"] = encodeFpe2(6000.0)
        keys["F0Mn"] = encodeFpe2(1200.0)
        keys["FS!"] = encodeUi16(0)
        keys["CHLC"] = encodeUi16(0) // non-nil for detection
        #endif
    }

    func readKeyRaw(_ key: String) -> (dataType: UInt32, bytes: [UInt8])? {
        return keys[key]
    }

    func writeKeyRaw(_ key: String, dataType: UInt32, bytes: [UInt8]) -> Bool {
        writtenKeys.append(MockSMCWrittenKey(key: key, dataType: dataType, bytes: bytes))
        #if arch(arm64)
        if key == "F0Md" {
            keys["F0Md"] = (dataType, bytes)
        }
        #endif
        return true
    }

    private func encodeFlt(_ value: Float) -> (UInt32, [UInt8]) {
        let raw = value.bitPattern
        return (
            smcEncodeKey("flt "),
            [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        )
    }

    private func encodeFpe2(_ value: Double) -> (UInt32, [UInt8]) {
        let raw = UInt16((value * 256.0).rounded())
        return (
            smcEncodeKey("fpe2"),
            [
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        )
    }

    private func encodeUi8(_ value: UInt8) -> (UInt32, [UInt8]) {
        return (smcEncodeKey("ui8 "), [value])
    }

    private func encodeUi16(_ value: UInt16) -> (UInt32, [UInt8]) {
        return (
            smcEncodeKey("ui16"),
            [
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        )
    }

    private func encodeUi32(_ value: UInt32) -> (UInt32, [UInt8]) {
        return (
            smcEncodeKey("ui32"),
            [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        )
    }
}

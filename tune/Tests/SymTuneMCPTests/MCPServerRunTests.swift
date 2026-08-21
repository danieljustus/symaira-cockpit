import XCTest
import SymairaMCP
@testable import SymTuneMCP
@testable import SymTuneCore

/// End-to-end tests over the wire: drive `TuneMCPServer` through
/// `MCPStdioTransport` and verify JSON-RPC behaviour (handshake, ping,
/// notifications, error mapping) as a client would see it.
final class MCPServerRunTests: XCTestCase {

    // MARK: - run() loop

    func testRunInitializeReturnsResponse() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.id, .number(1))
        let result = try XCTUnwrap(try mcpDecodeResult(envelope, as: MCPInitializeResult.self))
        XCTAssertNotNil(result.protocolVersion)
        XCTAssertNotNil(result.capabilities)
        XCTAssertEqual(result.serverInfo.name, "symtune")
        XCTAssertEqual(result.serverInfo.version, TuneVersion.current)
    }

    func testRunPingReturnsEmptyResult() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.id, .number(2))
        XCTAssertEqual(envelope.result, .object([:]))
    }

    func testRunNotificationIsIgnored() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        // A notification must not produce a response: the next line read must
        // be the response to the subsequent ping.
        try mcpSend(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: harness.clientWrite)
        try mcpSend(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.id, .number(3))
        XCTAssertNotNil(envelope.result)
    }

    func testRunUnknownMethodReturnsMethodNotFoundError() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend(#"{"jsonrpc":"2.0","id":4,"method":"unknown/method"}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.id, .number(4))
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32601)
    }

    func testRunUnsupportedToolReturnsInternalError() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nonexistent_tool","arguments":{"fraction":0.5}}}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.id, .number(5))
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertTrue(envelope.error?.message.contains("Unknown tool") == true)
    }

    func testRunMalformedJSONReturnsParseError() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend("this is not json", to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.error?.code, -32700)
    }

    func testRunInvalidRequestReturnsInvalidRequestError() async throws {
        let harness = try MCPTestHarness.make()
        defer { try? harness.clientWrite.close() }

        try mcpSend(#"{"jsonrpc":"2.0","id":6}"#, to: harness.clientWrite)
        let envelope = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))
        XCTAssertEqual(envelope.error?.code, -32600)
    }

    func testRunEOFEndsServerLoop() async throws {
        let harness = try MCPTestHarness.make()

        try mcpSend(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, to: harness.clientWrite)
        _ = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))

        try harness.clientWrite.close()
        try await harness.serverTask.value
    }

    func testRunStopEndsServerLoop() async throws {
        let harness = try MCPTestHarness.make()

        try mcpSend(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, to: harness.clientWrite)
        _ = try mcpDecodeEnvelope(try await mcpNextLine(harness.reader))

        harness.server.stop()
        try await harness.serverTask.value
    }
}

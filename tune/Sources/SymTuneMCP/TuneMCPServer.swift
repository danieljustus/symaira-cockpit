import Foundation
import SymTuneCore
import SymairaMCP

/// MCP server for symtune, built on appkit's shared `SymairaMCP` module.
///
/// Registers the `tools/list` and `tools/call` handlers on
/// `MCPServer.withMethodHandler(_:)` and serves them over
/// `MCPStdioTransport` (newline-delimited JSON-RPC, per the MCP spec's stdio
/// framing). Zero stdout pollution: only protocol frames are written to
/// standard output.
///
/// The tool set is identical to the pre-migration hand-rolled server: the
/// same names, descriptions, schemas (including JSON Schema `minimum` /
/// `maximum` safety bounds), and read-only filtering when
/// `config.isMCPReadOnly` is set.
public final class TuneMCPServer: Sendable {
    private let controller: TuneController
    private let registry: TuneToolRegistry

    public convenience init(controller: TuneController = TuneController(), config: TuneConfig? = nil) {
        let loadedConfig = config ?? ConfigPaths().loadConfig()
        self.init(controller: controller, config: loadedConfig)
    }

    init(controller: TuneController = TuneController(), config: TuneConfig = TuneConfig()) {
        self.controller = controller
        let availableTools = config.isMCPReadOnly
            ? TuneToolRegistry.defaultTools.filter(\.isReadOnly)
            : TuneToolRegistry.defaultTools
        self.registry = TuneToolRegistry(tools: availableTools)
    }

    /// Runs the server until stdin closes (EOF) or `stop()` is called on the
    /// underlying transport. Synchronous bridge over the async server loop,
    /// so the CLI can `try TuneMCPServer(...).run()` from `runMain()`.
    public func run() throws {
        let server = makeServer()
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = StartErrorBox()
        Task.detached {
            do {
                try await server.start(transport: MCPStdioTransport())
            } catch {
                errorBox.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = errorBox.error { throw error }
    }

    /// Builds the appkit `MCPServer` with the `tools` capability registered.
    /// Internal so tests can drive the server over an in-process transport.
    func makeServer() -> MCPServer {
        let server = MCPServer(name: "symtune", version: TuneVersion.current)
        server.withMethodHandler("tools/list") { (_: MCPNoParams) async throws -> MCPListToolsResult in
            MCPListToolsResult(tools: self.registry.schemas())
        }
        server.withMethodHandler("tools/call") { (params: MCPCallToolParams) async throws -> MCPCallToolResult in
            try self.callTool(name: params.name, arguments: params.arguments ?? [:])
        }
        return server
    }

    // MARK: - tools/call

    private func callTool(name: String, arguments: [String: MCPJSONValue]) throws -> MCPCallToolResult {
        guard let tool = registry.tool(named: name) else {
            // Read-only mode removes write tools from the registry, so a
            // filtered-out tool is indistinguishable from an unknown one.
            throw MCPError("Unknown tool '\(name)'.")
        }
        let payload = try tool.invoke(arguments: arguments, controller: controller)
        let text = try Self.encodeResult(payload)
        return MCPCallToolResult(content: [MCPTextContent(text: text)], isError: false)
    }

    /// Encodes a tool result with the project's wire conventions: snake_case
    /// keys and sorted keys, as a single JSON text block.
    private static func encodeResult(_ value: any Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodable(value))
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError("Failed to encode tool result.")
        }
        return text
    }
}

/// Type-erasing wrapper so heterogeneous `Encodable` payloads share one encode path.
private struct AnyEncodable: Encodable {
    private let encodeImpl: (any Encoder) throws -> Void
    init(_ wrapped: any Encodable) { self.encodeImpl = wrapped.encode(to:) }
    func encode(to encoder: any Encoder) throws { try encodeImpl(encoder) }
}

/// Thread-safe box for the error thrown by the async server loop, so the
/// synchronous `run()` bridge can rethrow it after the semaphore is signalled.
private final class StartErrorBox: @unchecked Sendable {
    var error: Error?
}

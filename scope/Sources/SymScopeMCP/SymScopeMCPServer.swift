import Foundation
import SymScopeCore
import SymairaMCP

/// MCP server for `symscope` — inventories ports, containers, and MCP servers
/// over stdio JSON-RPC. Zero stdout pollution: only JSON-RPC frames.
public final class SymScopeMCPServer: @unchecked Sendable {
    private let server: SymairaMCP.MCPServer

    public init() {
        self.server = SymairaMCP.MCPServer(name: "symscope", version: Version.version)
        registerHandlers()
    }

    /// Serves MCP over stdio until stdin closes.
    public func runServe() throws {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await server.start(transport: MCPStdioTransport())
            } catch {
                fputs("symscope: MCP server error: \(error)\n", stderr)
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// In-process dispatch (used by tests).
    public func dispatch(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "symscope", "version": Version.version],
            ]
        case "notifications/initialized":
            return [:]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools()]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPServerError.invalidParams("tools/call requires a tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name, arguments: arguments)
        default:
            throw MCPServerError.methodNotFound("Unknown method: \(method)")
        }
    }

    // MARK: - Wire handlers

    private func registerHandlers() {
        server
            .withMethodHandler("initialize") { [self] (params: MCPInitializeParams) async throws -> MCPJSONValue in
                .object([
                    "protocolVersion": .string(params.protocolVersion ?? MCPServer.supportedProtocolVersion),
                    "serverInfo": .object([
                        "name": .string("symscope"),
                        "version": .string(Version.version),
                    ]),
                ])
            }
            .withMethodHandler("tools/list") { [self] (_: MCPNoParams) async throws -> MCPJSONValue in
                .object(["tools": .array(tools().map(Self.jsonValue))])
            }
            .withMethodHandler("tools/call") { [self] (params: MCPCallToolParams) async throws -> MCPJSONValue in
                let arguments = (params.arguments ?? [:]).mapValues { value -> Any in
                    switch value {
                    case .string(let s): return s
                    case .number(let n): return n
                    case .bool(let b): return b
                    case .null: return NSNull()
                    case .array(let a): return a.map { Self.jsonAny($0) }
                    case .object(let o): return o.mapValues { Self.jsonAny($0) }
                    }
                }
                do {
                    return Self.jsonValue(try await callTool(params.name, arguments: arguments))
                } catch {
                    throw MCPError(error.localizedDescription)
                }
            }
    }

    // MARK: - Tools

    func tools() -> [[String: Any]] {
        [
            [
                "name": "scan",
                "description": "Aggregate snapshot: listening ports, MCP servers, containers",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "ports_list",
                "description": "List local listening TCP/UDP ports with owning process",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "ports_suggest",
                "description": "Suggest N free TCP ports",
                "inputSchema": [
                    "type": "object",
                    "properties": ["count": ["type": "integer", "description": "number of ports (default 3)"]],
                ],
            ],
            [
                "name": "mcp_list",
                "description": "List MCP servers configured across AI clients",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "conflicts",
                "description": "Ports held by multiple processes",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "mcp_health",
                "description": "Health-probe configured MCP servers",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
        ]
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        switch name {
        case "scan":
            let snapshot = await SnapshotService.build()
            return toolResult(try encoder.encode(snapshot))

        case "ports_list":
            let ports = try await PortService.listListening()
            return toolResult(try encoder.encode(ports))

        case "ports_suggest":
            let count = arguments["count"] as? Int ?? 3
            let ports = try await PortService.suggestFree(count: count)
            return toolResult(try encoder.encode(ports))

        case "mcp_list":
            let (servers, _) = MCPDiscovery.discover()
            return toolResult(try encoder.encode(servers))

        case "conflicts":
            let ports = try await PortService.listListening()
            let conflicts = ConflictDetector.detect(ports)
            return toolResult(try encoder.encode(conflicts))

        case "mcp_health":
            let (servers, _) = MCPDiscovery.discover()
            let results = await MCPHealthService.checkAll(servers)
            return toolResult(try encoder.encode(results))

        default:
            throw MCPServerError.invalidParams("Unknown tool: \(name)")
        }
    }

    private func toolResult(_ data: Data) -> [String: Any] {
        [
            "content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]],
            "isError": false,
        ]
    }

    // MARK: - JSON bridging

    private static func jsonAny(_ value: MCPJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { jsonAny($0) }
        case .object(let o): return o.mapValues { jsonAny($0) }
        }
    }

    private static func jsonValue(_ value: Any) -> MCPJSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map { jsonValue($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { jsonValue($0) })
        default:
            return .null
        }
    }
}

enum MCPServerError: Error, LocalizedError {
    case invalidParams(String)
    case methodNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let msg): return msg
        case .methodNotFound(let msg): return msg
        }
    }
}

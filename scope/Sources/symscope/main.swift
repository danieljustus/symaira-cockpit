import Foundation
import SymScopeCore
import SymScopeMCP

// symscope — CLI entrypoint. Argument routing by hand (no third-party
// dependency), mirroring the Go cobra command surface.

let version = Version.info()

let args = Array(CommandLine.arguments.dropFirst())

// Encoder for output. Models declare explicit snake_case CodingKeys, so no
// key strategy conversion is applied (that would double-convert and break
// keys like generated_at / config_path).
func makeEncoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    if pretty {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    return encoder
}

func printJSON<T: Encodable>(_ value: T, pretty: Bool = true) throws {
    let encoder = makeEncoder(pretty: pretty)
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

func usage() -> Never {
    let text = """
    symscope — inventory local ports, containers, and MCP servers

    Usage:
      symscope version               print version info (--json for machine output)
      symscope scan                  aggregate snapshot (ports, MCP, containers)
      symscope ports list            listening ports (JSON)
      symscope ports suggest [n]     suggest free TCP ports (default 3)
      symscope mcp list              MCP servers across AI clients (JSON)
      symscope mcp health            health-probe configured MCP servers
      symscope containers            running Docker containers (JSON)
      symscope conflicts             ports held by multiple processes
      symscope watch --interval <s>  watch for changes (NDJSON events)
      symscope cache show|clear      inspect/clear the snapshot cache
      symscope explain port|server   explain what uses a port or server
      symscope serve                 run the stdio MCP server
      symscope help                  this text
    """
    fputs(text, stderr)
    exit(2)
}

@main
struct SymScopeMain {
    static func main() async {
        do {
            try await run(args)
        } catch {
            fputs("symscope: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

func run(_ args: [String]) async throws {
    guard let first = args.first else { usage() }

    switch first {
    case "version":
        let json = args.contains("--json")
        if json {
            try printJSON(Version.info(), pretty: false)
        } else {
            print("symscope \(Version.version) (schema_version \(Version.info().schemaVersion))")
        }

    case "scan":
        let snapshot = await SnapshotService.build()
        try printJSON(snapshot)

    case "ports":
        guard args.count >= 2 else { usage() }
        switch args[1] {
        case "list":
            let ports = try await PortService.listListening()
            try printJSON(ports)
        case "suggest":
            let count = args.count >= 3 ? (Int(args[2]) ?? 3) : 3
            let ports = try await PortService.suggestFree(count: count)
            try printJSON(ports)
        default:
            usage()
        }

    case "mcp":
        guard args.count >= 2 else { usage() }
        switch args[1] {
        case "list":
            let (servers, _) = MCPDiscovery.discover()
            try printJSON(servers)
        case "health":
            let (servers, _) = MCPDiscovery.discover()
            let results = await MCPHealthService.checkAll(servers)
            try printJSON(results)
        default:
            usage()
        }

    case "containers":
        let (containers, _) = await ContainerService.list()
        try printJSON(containers)

    case "watch":
        guard args.count >= 3, args[1] == "--interval", let interval = Double(args[2]), interval > 0 else {
            fputs("symscope: watch requires --interval <seconds>\n", stderr)
            exit(2)
        }
        var old = await SnapshotService.build()
        try printJSON(old, pretty: false)
        while true {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let new = await SnapshotService.build()
            let events = WatchService.diff(old: old, new: new)
            if !events.isEmpty {
                for event in events {
                    try printJSON(event, pretty: false)
                }
            }
            old = new
        }

    case "cache":
        guard args.count >= 2 else { usage() }
        switch args[1] {
        case "show":
            try printJSON(CacheService.stats())
        case "clear":
            if let error = CacheService.clear() {
                fputs("symscope: \(error)\n", stderr)
                exit(1)
            }
            print("Cache cleared.")
        default:
            usage()
        }

    case "explain":
        guard args.count >= 3 else { usage() }
        switch args[1] {
        case "port":
            guard let port = Int(args[2]) else {
                fputs("symscope: explain port requires a numeric port\n", stderr)
                exit(2)
            }
            let ports = try await PortService.listListening()
            let (servers, _) = MCPDiscovery.discover()
            try printJSON(ExplainService.explainPort(port, ports: ports, servers: servers))
        case "server":
            let (servers, _) = MCPDiscovery.discover()
            guard let explanation = ExplainService.explainServer(args[2], servers: servers) else {
                fputs("symscope: unknown MCP server '\(args[2])'\n", stderr)
                exit(1)
            }
            try printJSON(explanation)
        default:
            usage()
        }

    case "conflicts":
        let ports = try await PortService.listListening()
        let conflicts = ConflictDetector.detect(ports)
        try printJSON(conflicts)

    case "serve":
        // MCP server transport; stdout is JSON-RPC frames only.
        let server = SymScopeMCPServer()
        try server.runServe()

    case "help", "--help", "-h":
        usage()

    default:
        usage()
    }
}

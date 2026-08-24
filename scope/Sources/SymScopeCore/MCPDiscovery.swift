import Foundation

/// JSONC (JSON with comments) stripping — minimal, comment-aware scanner.
/// Handles // line comments and /* block comments, preserving strings so
/// comments inside strings are not stripped.
public enum JSONC {
    public static func strip(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            // Outside string
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    // line comment → skip to newline
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    // block comment → skip to */
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

/// MCP server config discovery across AI client applications.
///
/// Primary source: symbrain's harness inventory (`symbrain harness list
/// --output json`), the SSOT for which AI harnesses exist and where their
/// config files live (issue #19, symaira-brain#275). symbrain reports server
/// *names* only (JSON and TOML configs alike), not per-server command/args/
/// url — health probing of a symbrain-sourced server therefore reports
/// "unknown" (`MCPHealthService` already handles that transport gracefully).
///
/// Fallback source, used only when symbrain is absent (mirrors the Go
/// original, standalone-first like every other runtime integration):
/// - Claude Desktop / Claude Code: `~/Library/Application Support/Claude/claude_desktop_config.json`
/// - Cursor: `~/.cursor/mcp.json`
/// - VS Code: `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json` (Roo) — simplified to VS Code's own MCP config where present
/// - Windsurf: `~/.codeium/windsurf/mcp_config.json`
/// - Project-local: `./.mcp.json` (cwd)
public enum MCPDiscovery: Sendable {
    public struct Source: Sendable {
        public let client: String
        public let path: String
        public init(client: String, path: String) {
            self.client = client
            self.path = path
        }
    }

    public static func defaultSources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Source(client: "claude-desktop", path: "\(home)/Library/Application Support/Claude/claude_desktop_config.json"),
            Source(client: "cursor", path: "\(home)/.cursor/mcp.json"),
            Source(client: "windsurf", path: "\(home)/.codeium/windsurf/mcp_config.json"),
        ]
    }

    /// Returns (servers, notes). Notes carry non-fatal context (missing files,
    /// parse errors, and which inventory source was used).
    ///
    /// When symbrain is available, its harness inventory is authoritative and
    /// the built-in JSONC parse of `sources` is skipped entirely — reparsing
    /// configs symbrain already parsed (including codex's TOML, which this
    /// client cannot parse) would only reintroduce the two-list divergence
    /// this issue exists to remove.
    public static func discover(
        _ sources: [Source] = defaultSources(),
        harnessService: any HarnessInventoryProviding = SymBrainHarnessService()
    ) -> ([MCPServer], [String]) {
        if harnessService.isAvailable, let inventory = harnessService.list(projectDir: nil) {
            return discoverViaSymbrain(inventory)
        }
        return discoverBuiltin(sources)
    }

    private static func discoverViaSymbrain(_ inventory: HarnessInventory) -> ([MCPServer], [String]) {
        var servers: [MCPServer] = []
        var notes: [String] = ["mcp: source=symbrain (\(inventory.harnesses.count) harnesses)"]
        for harness in inventory.harnesses {
            for config in [harness.global, harness.project].compactMap({ $0 }) {
                if let error = config.error, !error.isEmpty {
                    notes.append("\(harness.name): \(error) in \(config.path)")
                    continue
                }
                guard config.parsed else { continue }
                for name in config.servers {
                    servers.append(MCPServer(
                        name: name,
                        client: harness.name,
                        transport: "unknown",
                        configPath: config.path,
                        source: "symbrain"
                    ))
                }
            }
        }
        return (servers, notes)
    }

    private static func discoverBuiltin(_ sources: [Source]) -> ([MCPServer], [String]) {
        var servers: [MCPServer] = []
        var notes: [String] = ["mcp: source=builtin (symbrain not installed)"]
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else {
                continue
            }
            guard let raw = try? String(contentsOfFile: source.path, encoding: .utf8) else {
                notes.append("\(source.client): unreadable config \(source.path)")
                continue
            }
            let stripped = JSONC.strip(raw)
            guard let data = stripped.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                notes.append("\(source.client): invalid JSON in \(source.path)")
                continue
            }
            // Claude-style: { "mcpServers": { name: {...} } }
            // Cursor-style:  { "mcpServers": { ... } }
            if let mcpServers = json["mcpServers"] as? [String: Any] {
                for (name, value) in mcpServers {
                    if let dict = value as? [String: Any] {
                        servers.append(parseServer(name: name, client: source.client, configPath: source.path, dict: dict))
                    }
                }
            } else {
                notes.append("\(source.client): no mcpServers key in \(source.path)")
            }
        }
        return (servers, notes)
    }

    private static func parseServer(name: String, client: String, configPath: String, dict: [String: Any]) -> MCPServer {
        let command = dict["command"] as? String
        let args = dict["args"] as? [String] ?? []
        let url = dict["url"] as? String
        let transport: String
        if url != nil {
            transport = (dict["type"] as? String) ?? "http"
        } else {
            transport = "stdio"
        }
        let env = dict["env"] as? [String: String] ?? [:]
        let secretBacked = dict["secret_backed"] as? Bool ?? false
        let warnings = dict["credential_warnings"] as? [String] ?? []
        return MCPServer(
            name: name,
            client: client,
            transport: transport,
            command: command,
            args: args,
            url: url,
            configPath: configPath,
            env: env,
            secretBacked: secretBacked,
            credentialWarnings: warnings
        )
    }
}

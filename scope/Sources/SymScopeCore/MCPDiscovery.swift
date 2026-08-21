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
/// Sources (mirrors the Go original):
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
    /// parse errors) just like the Go original.
    public static func discover(_ sources: [Source] = defaultSources()) -> ([MCPServer], [String]) {
        var servers: [MCPServer] = []
        var notes: [String] = []
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

import XCTest
@testable import SymScopeCore

private struct FakeHarnessService: HarnessInventoryProviding {
    let available: Bool
    let inventory: HarnessInventory?

    var isAvailable: Bool { available }
    func list(projectDir: String?) -> HarnessInventory? { inventory }
}

final class MCPDiscoveryTests: XCTestCase {
    func testDiscoverUsesBuiltinFallbackWhenSymbrainUnavailable() {
        let fake = FakeHarnessService(available: false, inventory: nil)
        let (servers, notes) = MCPDiscovery.discover([], harnessService: fake)

        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(notes.contains { $0.hasPrefix("mcp: source=builtin") })
    }

    func testDiscoverFallsBackToBuiltinWhenSymbrainAvailableButListFails() {
        // isAvailable true (binary found) but the subprocess call itself
        // failed (timeout, non-zero exit, malformed JSON) — list() returns nil.
        let fake = FakeHarnessService(available: true, inventory: nil)
        let (servers, notes) = MCPDiscovery.discover([], harnessService: fake)

        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(notes.contains { $0.hasPrefix("mcp: source=builtin") })
    }

    func testDiscoverUsesSymbrainInventoryWhenAvailable() {
        let inventory = HarnessInventory(
            schemaVersion: 1,
            projectDir: nil,
            harnesses: [
                HarnessInventoryEntry(
                    name: "codex",
                    displayName: "Codex",
                    global: HarnessConfigInventory(
                        path: "/home/user/.codex/config.toml",
                        exists: true,
                        parsed: true,
                        error: nil,
                        servers: ["symbrain", "filesystem"]
                    ),
                    project: nil
                ),
                HarnessInventoryEntry(
                    name: "claude",
                    displayName: "Claude Code",
                    global: HarnessConfigInventory(
                        path: "/home/user/.claude.json",
                        exists: false,
                        parsed: false,
                        error: nil,
                        servers: []
                    ),
                    project: nil
                )
            ]
        )
        let fake = FakeHarnessService(available: true, inventory: inventory)
        let (servers, notes) = MCPDiscovery.discover([], harnessService: fake)

        XCTAssertEqual(servers.count, 2)
        XCTAssertTrue(servers.allSatisfy { $0.source == "symbrain" })
        XCTAssertTrue(servers.allSatisfy { $0.transport == "unknown" })
        XCTAssertTrue(servers.allSatisfy { $0.client == "codex" })
        XCTAssertEqual(Set(servers.map { $0.name }), ["symbrain", "filesystem"])
        XCTAssertTrue(notes.contains { $0.hasPrefix("mcp: source=symbrain (2 harnesses)") })
    }

    func testDiscoverSurfacesSymbrainConfigErrorsAsNotes() {
        let inventory = HarnessInventory(
            schemaVersion: 1,
            projectDir: nil,
            harnesses: [
                HarnessInventoryEntry(
                    name: "cursor",
                    displayName: "Cursor",
                    global: HarnessConfigInventory(
                        path: "/home/user/.cursor/mcp.json",
                        exists: true,
                        parsed: false,
                        error: "invalid JSON",
                        servers: []
                    ),
                    project: nil
                )
            ]
        )
        let fake = FakeHarnessService(available: true, inventory: inventory)
        let (servers, notes) = MCPDiscovery.discover([], harnessService: fake)

        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(notes.contains { $0.contains("invalid JSON") && $0.contains("/home/user/.cursor/mcp.json") })
    }

    func testDiscoverIncludesProjectLocalServers() {
        let inventory = HarnessInventory(
            schemaVersion: 1,
            projectDir: "/repo",
            harnesses: [
                HarnessInventoryEntry(
                    name: "claude",
                    displayName: "Claude Code",
                    global: HarnessConfigInventory(
                        path: "/home/user/.claude.json", exists: false, parsed: false, error: nil, servers: []
                    ),
                    project: HarnessConfigInventory(
                        path: "/repo/.mcp.json", exists: true, parsed: true, error: nil, servers: ["local-tool"]
                    )
                )
            ]
        )
        let fake = FakeHarnessService(available: true, inventory: inventory)
        let (servers, _) = MCPDiscovery.discover([], harnessService: fake)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "local-tool")
        XCTAssertEqual(servers[0].configPath, "/repo/.mcp.json")
    }

    func testDiscoverBuiltinFallbackPreservesFullServerDetail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configPath = dir.appendingPathComponent("mcp.json")
        let config = """
        {
          // a comment, proving JSONC stripping still runs on the fallback path
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem"]
            }
          }
        }
        """
        try config.write(to: configPath, atomically: true, encoding: .utf8)

        let source = MCPDiscovery.Source(client: "cursor", path: configPath.path)
        let fake = FakeHarnessService(available: false, inventory: nil)
        let (servers, notes) = MCPDiscovery.discover([source], harnessService: fake)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "filesystem")
        XCTAssertEqual(servers[0].source, "builtin")
        XCTAssertEqual(servers[0].command, "npx")
        XCTAssertEqual(servers[0].args, ["-y", "@modelcontextprotocol/server-filesystem"])
        XCTAssertTrue(notes.contains { $0.hasPrefix("mcp: source=builtin") })
    }
}

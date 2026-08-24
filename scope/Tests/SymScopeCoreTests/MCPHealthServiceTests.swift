import XCTest
@testable import SymScopeCore

final class MCPHealthServiceTests: XCTestCase {
    private func server(
        name: String = "s",
        transport: String,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil
    ) -> MCPServer {
        MCPServer(name: name, client: "c", transport: transport, command: command, args: args, url: url, configPath: "/p")
    }

    // MARK: - stdio

    func testCheckStdioHealthyWithAbsolutePath() async {
        let result = await MCPHealthService.check(server(transport: "stdio", command: "/bin/echo"), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "healthy")
        XCTAssertNil(result.error)
        XCTAssertGreaterThanOrEqual(result.latencyMs, 0)
    }

    func testCheckStdioHealthyResolvedViaPath() async {
        // No slash in the command — exercises the /usr/bin/env PATH-resolution branch.
        let result = await MCPHealthService.check(server(transport: "stdio", command: "true"), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "healthy")
    }

    func testCheckStdioUnhealthyNonzeroExit() async {
        let result = await MCPHealthService.check(server(transport: "stdio", command: "/usr/bin/false"), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "unhealthy")
        XCTAssertEqual(result.error, "stdio spawn/read failed")
    }

    func testCheckStdioUnhealthySpawnFailure() async {
        let result = await MCPHealthService.check(
            server(transport: "stdio", command: "/nonexistent/does-not-exist-xyz"),
            timeoutSeconds: 2
        )
        XCTAssertEqual(result.status, "unhealthy")
        XCTAssertEqual(result.error, "stdio spawn/read failed")
    }

    func testCheckStdioUnhealthyMissingCommand() async {
        let result = await MCPHealthService.check(server(transport: "stdio", command: nil), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "unhealthy")
    }

    func testCheckStdioTimesOutSlowProcess() async {
        // A process that outlives the timeout must be reported unhealthy,
        // whether it is caught by the explicit deadline check or exits on
        // its own after being torn down — the contract is "never healthy
        // past the timeout", not the exact internal reason.
        let result = await MCPHealthService.check(
            server(transport: "stdio", command: "/bin/sleep", args: ["2"]),
            timeoutSeconds: 0.05
        )
        XCTAssertEqual(result.status, "unhealthy")
    }

    // MARK: - http / sse

    func testCheckHTTPMissingURL() async {
        let result = await MCPHealthService.check(server(transport: "http", url: nil), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "unhealthy")
        XCTAssertEqual(result.error, "missing url")
    }

    func testCheckHTTPHealthy() async throws {
        let httpServer = try await MiniHTTPServer()
        defer { httpServer.stop() }
        let target = server(transport: "http", url: "http://127.0.0.1:\(httpServer.port)/")
        let result = await MCPHealthService.check(target, timeoutSeconds: 2)
        XCTAssertEqual(result.status, "healthy")
        XCTAssertNil(result.error)
    }

    func testCheckSSEHealthy() async throws {
        let httpServer = try await MiniHTTPServer()
        defer { httpServer.stop() }
        let target = server(transport: "sse", url: "http://127.0.0.1:\(httpServer.port)/")
        let result = await MCPHealthService.check(target, timeoutSeconds: 2)
        XCTAssertEqual(result.status, "healthy")
    }

    func testCheckHTTPUnhealthyConnectionRefused() async throws {
        let port = try await reserveAndReleaseEphemeralPort()
        let target = server(transport: "http", url: "http://127.0.0.1:\(port)/")
        let result = await MCPHealthService.check(target, timeoutSeconds: 2)
        XCTAssertEqual(result.status, "unhealthy")
        XCTAssertEqual(result.error, "http probe failed")
    }

    // MARK: - unknown transport

    func testCheckUnknownTransport() async {
        let result = await MCPHealthService.check(server(transport: "websocket"), timeoutSeconds: 2)
        XCTAssertEqual(result.status, "unknown")
        XCTAssertEqual(result.latencyMs, 0)
    }

    // MARK: - checkAll

    func testCheckAllAggregatesMultipleServers() async {
        let servers = [
            server(name: "a", transport: "stdio", command: "/bin/echo"),
            server(name: "b", transport: "websocket"),
        ]
        let results = await MCPHealthService.checkAll(servers, timeoutSeconds: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "a")
        XCTAssertEqual(results[0].status, "healthy")
        XCTAssertEqual(results[1].name, "b")
        XCTAssertEqual(results[1].status, "unknown")
    }

    func testCheckAllEmptyList() async {
        let results = await MCPHealthService.checkAll([], timeoutSeconds: 2)
        XCTAssertTrue(results.isEmpty)
    }
}

import Foundation
import XCTest

/// Exercises the released `symcockpit scope serve` command over stdio so the
/// MCP initialize capabilities and tools/list contract stay wire-compatible.
final class SymScopeServeIntegrationE2ETests: XCTestCase {
    private let frameTimeout: TimeInterval = 30

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not locate the products directory")
    }

    func testScopeServeInitializeCapabilitiesAndToolsList() throws {
        let process = try launchScopeServe()
        defer { process.cleanupIfRunning() }

        try process.writeFrame(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let initialize = try parseFrame(process.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual(initialize["jsonrpc"] as? String, "2.0")
        XCTAssertNil(initialize["error"])
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"] as? [String: Any])

        try process.writeFrame(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let toolsEnvelope = try parseFrame(process.waitForNextFrame(timeout: frameTimeout))
        XCTAssertNil(toolsEnvelope["error"])
        let toolsResult = try XCTUnwrap(toolsEnvelope["result"] as? [String: Any])
        let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["scan", "ports_list", "ports_suggest", "mcp_list", "conflicts", "mcp_health", "daemons_list"])

        process.closeStdin()
        XCTAssertTrue(process.waitForExit(timeout: frameTimeout))
        XCTAssertEqual(process.exitCode, 0)
    }

    private func launchScopeServe() throws -> ServeChild {
        let executable = productsDirectory.appendingPathComponent("symcockpit").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["scope", "serve"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let child = ServeChild(
            process: process,
            stdin: stdin.fileHandleForWriting,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        try child.start()
        return child
    }

    private func parseFrame(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ServeTestError.unparseableFrame(line)
        }
        return dictionary
    }
}

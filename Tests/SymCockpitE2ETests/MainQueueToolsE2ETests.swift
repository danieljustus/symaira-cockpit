import Foundation
import XCTest

final class MainQueueToolsE2ETests: XCTestCase {
    func testMainQueueToolsRespondAndServerExits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let process = Process()
        process.executableURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("symcockpit")
        process.arguments = ["tune", "serve"]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let child = ServeChild(process: process, stdin: input.fileHandleForWriting,
                               stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
        try child.start()
        defer { child.cleanupIfRunning() }

        func request(_ id: Int, _ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
            let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            let data = try JSONSerialization.data(withJSONObject: frame)
            try child.writeFrame(String(decoding: data, as: UTF8.self))
            let reply = try child.waitForNextFrame(timeout: 10)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            XCTAssertEqual(envelope["id"] as? Int, id)
            XCTAssertNil(envelope["error"], reply)
            return try XCTUnwrap(envelope["result"] as? [String: Any])
        }
        func tool(_ id: Int, _ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
            let result = try request(id, "tools/call", params: ["name": name, "arguments": arguments])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        _ = try request(1, "initialize")
        // Saving only reads hardware. DimOverlay.dimLevel needs the main queue.
        let saved = try tool(2, "save_profile", arguments: ["name": "main-queue-test"])
        XCTAssertEqual(saved["saved"] as? String, "main-queue-test")
        let profileURL = root.appendingPathComponent("data/symtune/profile-main-queue-test.json")
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: profileURL)) as? [String: Any])
        XCTAssertEqual(persisted["name"] as? String, "main-queue-test")
        XCTAssertEqual(persisted["dim"] as? Double, 1)
        let listed = try tool(3, "list_profiles")
        XCTAssertEqual((listed["profiles"] as? [[String: Any]])?.count, 1)
        // A separate read-only caller has the same main-queue dependency.
        let status = try tool(4, "get_status")
        XCTAssertNotNil(status["health_score"])
        _ = try tool(5, "delete_profile", arguments: ["name": "main-queue-test"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        _ = try request(6, "ping")
        child.closeStdin()
        XCTAssertTrue(child.waitForExit(timeout: 10))
        XCTAssertEqual(child.exitCode, 0)
        XCTAssertEqual(child.stdoutLines().count, 6)
    }
}

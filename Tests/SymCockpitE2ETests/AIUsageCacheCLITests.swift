import Foundation
import XCTest

/// Hermetic process-level evidence: the real Cockpit executable talks only to
/// a fixture Brain executable. No provider credentials or endpoints are used.
final class AIUsageCacheCLITests: XCTestCase {
    func testSelectionCacheAcrossProcessesAndForceRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.run(["codex", "--json"])
        XCTAssertEqual(first.status, 0)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: first.output) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["provider_id"] as? String, "codex")
        XCTAssertEqual(try fixture.calls(), ["usage --output json --providers codex"])
        let second = try fixture.run(["codex", "--json"])
        XCTAssertEqual(second.status, 0)
        XCTAssertEqual(try fixture.calls().count, 1, "A new process should use the same fresh cache")
        XCTAssertEqual(first.output, second.output)
        XCTAssertEqual(try fixture.run(["codex", "--json", "--force"]).status, 0)
        XCTAssertEqual(try fixture.calls().count, 2)
    }

    func testUnknownProviderAndFlagsDoNotInvokeBrain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for args in [["not-a-provider"], ["codex", "claude"], ["--unknown"]] {
            XCTAssertEqual(try fixture.run(args).status, 2)
        }
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    private struct Fixture {
        let root: URL
        let binary: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-cli-" + UUID().uuidString)
            let products = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
                .bundleURL.deletingLastPathComponent()
            binary = products.appendingPathComponent("symcockpit")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let report: [String: Any] = ["schema_version": 1, "providers": [[
                "id": "codex", "display_name": "Codex", "configured": true,
                "auth_status": ["status": "available", "detail": "test fixture"],
                "snapshot": ["provider_id": "codex", "source": "test fixture", "fetched_at": Date().ISO8601Format(),
                             "meters": [["label": "Session", "used": "42", "limit": "100", "unit": "percent"]]]
            ]]]
            try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("report.json"))
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls"
            exec /bin/cat "$FIXTURE_ROOT/report.json"
            """
            let executable = root.appendingPathComponent("bin/symbrain")
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func run(_ args: [String]) throws -> (status: Int32, output: Data) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["ai-usage"] + args
            process.environment = [
                "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "HOME": root.path, "CFFIXED_USER_HOME": root.path,
                "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "XDG_DATA_HOME": root.appendingPathComponent("data").path,
                "FIXTURE_ROOT": root.path
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + 10) == .success else {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                throw NSError(domain: "AIUsageCacheCLITests.timeout", code: 1)
            }
            return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
        }

        func calls() throws -> [String] {
            let file = root.appendingPathComponent("calls")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

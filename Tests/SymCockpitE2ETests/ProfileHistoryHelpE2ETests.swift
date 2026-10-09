import Foundation
import XCTest

/// Contextual help must explain the shipped CLI without executing profile operations.
final class ProfileHistoryHelpE2ETests: XCTestCase {
    func testContextualHelpExplainsOptionsWithoutChangingProfilesOrHistory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-help-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let saved = try run(["profile", "save", "owned"], home: home)
        XCTAssertEqual(saved.code, 0, saved.output)
        let profileURL = home.appendingPathComponent("data/profile-owned.json")
        let original = try Data(contentsOf: profileURL)
        let history = try run(["history", "--json"], home: home).output
        let cases = [
            ["profile", "--help"], ["profile", "-h"],
            ["profile", "save", "--help"], ["profile", "delete", "owned", "--help"],
            ["history", "--help"], ["history", "-h"], ["history", "--limit", "5", "--help"],
        ]
        for prefix in [[], ["tune"]] as [[String]] {
            for command in cases {
                let result = try run(prefix + command, home: home)
                XCTAssertEqual(result.code, 0, "\(prefix + command): \(result.output)")
                XCTAssertTrue(result.output.contains("Usage: symcockpit \(command[0])"), result.output)
                if command[0] == "profile" {
                    for operation in ["save", "load", "list", "delete"] {
                        XCTAssertTrue(result.output.contains("symcockpit profile \(operation)"), result.output)
                    }
                } else {
                    XCTAssertTrue(result.output.contains("--json"), result.output)
                    XCTAssertTrue(result.output.contains("--limit"), result.output)
                    XCTAssertTrue(result.output.contains("100"), result.output)
                }
                XCTAssertEqual(try Data(contentsOf: profileURL), original)
                XCTAssertEqual(try run(["history", "--json"], home: home).output, history)
                let helpProfile = home.appendingPathComponent("data/profile---help.json")
                XCTAssertFalse(FileManager.default.fileExists(atPath: helpProfile.path))
            }
        }
        XCTAssertEqual(try run(["profile", "list", "--typo"], home: home).code, 2)
        XCTAssertEqual(try run(["history", "--typo"], home: home).code, 2)
    }

    private func run(_ args: [String], home: URL) throws -> (code: Int32, output: String) {
        let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let process = Process()
        process.executableURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("symcockpit")
        process.arguments = args + ["--data-dir", home.appendingPathComponent("data").path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "CFFIXED_USER_HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "SYMAIRA_CHECK_UPDATES": "false",
        ]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let child = ServeChild(process: process, stdin: input.fileHandleForWriting,
                               stdout: output.fileHandleForReading, stderr: error.fileHandleForReading)
        defer { child.cleanupIfRunning() }
        try child.start()
        child.closeStdin()
        guard child.waitForExit(timeout: 10) else {
            throw NSError(domain: "ProfileHistoryHelpE2ETests", code: 1)
        }
        return (child.exitCode, child.stdoutLines().joined(separator: "\n"))
    }
}

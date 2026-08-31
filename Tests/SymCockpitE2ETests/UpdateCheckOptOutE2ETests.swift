import Foundation
import XCTest

/// Verifies that the dispatcher can report versions without contacting GitHub
/// when update checks are explicitly disabled.
final class UpdateCheckOptOutE2ETests: XCTestCase {
    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("symcockpit")
        }
        fatalError("Could not locate the products directory")
    }

    func testNoUpdateCheckFlagSkipsNetworkAndKeepsJSONShape() throws {
        let result = try run(["version", "--json", "--no-update-check"])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(try updateStatus(from: result.stdout), "skipped")
    }

    func testEnvironmentOptOutSkipsNetwork() throws {
        let result = try run(
            ["version", "--json"],
            environment: ["SYMCOCKPIT_CHECK_UPDATES": "0"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(try updateStatus(from: result.stdout), "skipped")
    }

    func testTuneConfigOptOutIsHonoredByDispatcher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("symcockpit-update-check-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("symtune", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "[general]\ncheck_updates = false\n".write(
            to: configDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let result = try run(
            ["version", "--json"],
            environment: ["XDG_CONFIG_HOME": root.path]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(try updateStatus(from: result.stdout), "skipped")
    }

    func testPlainVersionReportsSkippedCheck() throws {
        let result = try run(["version", "--no-update-check"])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(result.stdout.contains("update check skipped"), result.stdout)
    }

    private func updateStatus(from stdout: String) throws -> String {
        let data = try XCTUnwrap(stdout.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let update = try XCTUnwrap(object["update"] as? [String: Any])
        return try XCTUnwrap(update["status"] as? String)
    }

    private func run(
        _ arguments: [String],
        environment overrides: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SYMCOCKPIT_CHECK_UPDATES")
        environment.removeValue(forKey: "SYMTUNE_CHECK_UPDATES")
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            stdout: String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            status: process.terminationStatus
        )
    }
}

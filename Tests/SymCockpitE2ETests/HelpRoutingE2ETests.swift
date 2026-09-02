import Foundation
import XCTest

/// Verifies that requested help is a successful stdout response while usage
/// caused by invalid dispatcher input remains an stderr usage error.
final class HelpRoutingE2ETests: XCTestCase {
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
        fatalError("Could not locate the products directory — not running within an XCTest bundle?")
    }

    func testRequestedHelpRoutesToStdoutAndExitsZero() throws {
        let surfaces: [[String]] = [
            ["--help"],
            ["tune", "--help"],
            ["operate", "--help"],
            ["scope", "--help"],
        ]

        for arguments in surfaces {
            let result = try run(arguments)
            XCTAssertEqual(result.status, 0, "\(arguments.joined(separator: " ")) should exit 0")
            XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(arguments.joined(separator: " ")) should print help to stdout")
            XCTAssertTrue(result.stderr.isEmpty,
                          "\(arguments.joined(separator: " ")) should not write help to stderr: \(result.stderr)")
        }
    }

    func testRootVersionAliasesMatchVersionOutput() throws {
        let version = try run(["version"])

        XCTAssertEqual(version.status, 0)
        XCTAssertTrue(version.stderr.isEmpty, version.stderr)
        for alias in ["--version", "-V"] {
            let result = try run([alias])
            XCTAssertEqual(result.status, 0, "\(alias) should exit 0")
            XCTAssertEqual(result.stdout, version.stdout, "\(alias) should match `version` output")
            XCTAssertEqual(result.stderr, version.stderr, "\(alias) should match `version` diagnostics")
        }
    }

    func testScopeVersionAliasesMatchVersionOutput() throws {
        let version = try run(["scope", "version"])

        XCTAssertEqual(version.status, 0)
        XCTAssertTrue(version.stderr.isEmpty, version.stderr)
        for alias in ["--version", "-V"] {
            let result = try run(["scope", alias])
            XCTAssertEqual(result.status, 0, "scope \(alias) should exit 0")
            XCTAssertEqual(result.stdout, version.stdout, "scope \(alias) should match scope version output")
            XCTAssertEqual(result.stderr, version.stderr, "scope \(alias) should match scope version diagnostics")
        }
    }

    func testUnknownFamilyKeepsUsageOnStderrAndExitsTwo() throws {
        let result = try run(["unknown-family"])

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("unknown family"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Usage:"), result.stderr)
    }

    func testUnknownScopeCommandKeepsUsageOnStderrAndExitsTwo() throws {
        let result = try run(["scope", "unknown-command"])

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("Usage:"), result.stderr)
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(
            stdout: stdout,
            stderr: stderr,
            status: process.terminationStatus
        )
    }
}

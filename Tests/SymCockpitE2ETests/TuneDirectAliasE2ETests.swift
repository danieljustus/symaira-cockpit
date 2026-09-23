import Foundation
import XCTest

/// Verifies the PB-2026-09-09 §4/§8 direct-alias layer: most `tune`
/// commands also work at the root, without the `tune` prefix, with
/// matching stdout/exit status. Legacy stderr includes a deprecation warning.
final class TuneDirectAliasE2ETests: XCTestCase {
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

    /// Every non-colliding tune command, invoked with --help only: real
    /// subcommands like `awake`/`brightness`/`fan` mutate live hardware
    /// state, so this suite (like TuneCLIE2ETests) never invokes them
    /// without --help.
    private let aliasedCommands = [
        "sensors", "battery", "displays", "metrics", "ai-usage",
        "processes", "top",
        "status", "awake", "brightness", "extbright", "dim", "warmth",
        "restore", "profile", "fan", "battery-limit", "doctor", "permissions", "history",
    ]


    func testDirectAliasMatchesTunePrefixedOutput() throws {
        for command in aliasedCommands {
            let direct = try run([command, "--help"])
            let prefixed = try run(["tune", command, "--help"])

            XCTAssertEqual(direct.stdout, prefixed.stdout,
                           "symcockpit \(command) --help should match symcockpit tune \(command) --help")
            XCTAssertTrue(prefixed.stderr.hasPrefix("symcockpit: 'tune' is deprecated;"),
                          "legacy route must announce the migration for \(command)")
            XCTAssertTrue(prefixed.stderr.hasSuffix(direct.stderr),
                          "legacy route must retain the command diagnostics for \(command)")
            XCTAssertEqual(direct.status, prefixed.status,
                           "symcockpit \(command) --help exit code should match the tune-prefixed form")
        }
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

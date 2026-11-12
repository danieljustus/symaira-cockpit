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


    /// The `tune` prefix was removed in v0.12 (#259): the direct command
    /// answers, the prefixed form names it and exits 2 without running it.
    func testDirectCommandAnswersAndTunePrefixNamesIt() throws {
        for command in aliasedCommands {
            let direct = try run([command, "--help"])
            let prefixed = try run(["tune", command, "--help"])

            // Some commands answer --help with a usage exit; only the routing
            // is under test here, not each command's help contract.
            XCTAssertFalse(direct.stderr.contains("unknown family"), "symcockpit \(command) must route directly")
            XCTAssertEqual(prefixed.status, 2, "the removed prefix is a usage error for \(command)")
            XCTAssertTrue(prefixed.stdout.isEmpty, "the removed prefix must not run \(command)")
            XCTAssertEqual(prefixed.stderr,
                           "symcockpit: the 'tune' prefix was removed; run 'symcockpit \(command) --help' instead.\n")
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

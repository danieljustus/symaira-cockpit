import Foundation
import XCTest

/// Verifies the PB-2026-09-09 §4/§8 direct-alias layer: most `tune`
/// commands also work at the root, without the `tune` prefix, with
/// byte-identical output — and the four names that collide with `operate`
/// (and, for `serve`, also `scope`) stay reachable only via `tune`.
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
        "restore", "profile", "fan", "battery-limit",
    ]

    /// Collides with `operate` (and `serve` additionally with `scope`) —
    /// must stay reachable only as `symcockpit tune <cmd>`.
    private let collidingCommands = ["doctor", "permissions", "serve", "history"]

    func testDirectAliasMatchesTunePrefixedOutput() throws {
        for command in aliasedCommands {
            let direct = try run([command, "--help"])
            let prefixed = try run(["tune", command, "--help"])

            XCTAssertEqual(direct.stdout, prefixed.stdout,
                           "symcockpit \(command) --help should match symcockpit tune \(command) --help")
            XCTAssertEqual(direct.stderr, prefixed.stderr,
                           "symcockpit \(command) --help diagnostics should match the tune-prefixed form")
            XCTAssertEqual(direct.status, prefixed.status,
                           "symcockpit \(command) --help exit code should match the tune-prefixed form")
        }
    }

    func testCollidingCommandsStayTunePrefixedOnly() throws {
        for command in collidingCommands {
            let bare = try run([command])
            XCTAssertEqual(bare.status, 2,
                           "symcockpit \(command) (no family prefix) must stay an unknown-family error, not silently alias to tune")
            XCTAssertTrue(bare.stderr.contains("unknown family"),
                          "symcockpit \(command) should report unknown family: \(bare.stderr)")
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

import Foundation
import XCTest

/// Executable acceptance checks for the reviewed PB command map. Every call
/// here is help/protocol-only and no hardware write is invoked.
final class CommandMapAcceptanceE2ETests: XCTestCase {
    private struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("symcockpit")
        }
        fatalError("Could not locate the products directory")
    }

    private let directTuneCommands = [
        "sensors", "battery", "displays", "metrics", "ai-usage", "processes", "top",
        "status", "awake", "brightness", "extbright", "dim", "warmth", "restore",
        "profile", "fan", "battery-limit",
    ]

    private let collidingTuneCommands = ["doctor", "permissions", "serve", "history"]

    func testEveryReviewedDirectAliasMatchesLegacyTuneRoute() throws {
        for command in directTuneCommands {
            for help in ["--help", "-h"] {
                let direct = try run([command, help])
                let legacy = try run(["tune", command, help])
                XCTAssertEqual(direct.status, legacy.status, command)
                XCTAssertEqual(direct.stdout, legacy.stdout, command)
                XCTAssertEqual(direct.stderr, legacy.stderr, command)
            }
        }
    }

    func testEveryCollisionRemainsNamespacedAndReachable() throws {
        for command in collidingTuneCommands {
            let bare = try run([command])
            XCTAssertEqual(bare.status, 2, command)
            XCTAssertTrue(bare.stderr.contains("unknown family"), bare.stderr)

            // `history` has no help mode; parse-error evidence still proves
            // the namespaced dispatcher reached the Tune handler.
            if command == "history" {
                let namespaced = try run(["tune", command, "--help"])
                XCTAssertEqual(namespaced.status, 2, command)
                XCTAssertTrue(namespaced.stderr.contains("history"), namespaced.stderr)
            } else if command == "serve" {
                // The safe stdio initialize/tools-list fixture covers serve;
                // launching it with --help would enter its blocking loop.
            } else {
                let namespaced = try run(["tune", command, "--help"])
                XCTAssertEqual(namespaced.status, 0, command)
                XCTAssertFalse(namespaced.stdout.isEmpty, command)
            }
        }
    }

    func testTuneFamilyAndVersionAliasesRemainExecutable() throws {
        let result = try run(["tune", "--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)

        let version = try run(["version"])
        for alias in ["--version", "-V"] {
            let result = try run([alias])
            XCTAssertEqual(result.status, 0, alias)
            XCTAssertEqual(result.stdout, version.stdout, alias)
            XCTAssertEqual(result.stderr, version.stderr, alias)
        }
    }

    func testRemovedFamiliesPrintMigrationHintAndExitFour() throws {
        for family in ["operate", "scope"] {
            let result = try run([family])
            XCTAssertEqual(result.status, 4, family)
            XCTAssertTrue(result.stdout.isEmpty, family)
            XCTAssertTrue(result.stderr.contains("Symaira Brain"), result.stderr)
            XCTAssertTrue(result.stderr.contains("--modules \(family)"), result.stderr)
        }
    }

    func testCompletionIsNotAdvertisedOrFalselyRouted() throws {
        for arguments in [["completion"], ["completion", "bash"], ["--completion"]] {
            let result = try run(arguments)
            XCTAssertEqual(result.status, 2, arguments.joined(separator: " "))
            XCTAssertTrue(result.stderr.contains("unknown family"), result.stderr)
            XCTAssertFalse(result.stdout.contains("completion"), result.stdout)
        }
    }

    private func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Result(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}

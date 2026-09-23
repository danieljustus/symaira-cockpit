import Foundation
import XCTest

/// End-to-end coverage for issue #285 through the public dispatcher binary.
///
/// Before the fix, `tune battery-limit set 9223372036854775807` and the same
/// value through `tune serve` (`set_charge_limit`) died with SIGTRAP inside
/// the shared `WriteCommand` integer conversion: the CLI exited on an
/// uncatchable signal and the MCP session vanished without an error response.
///
/// Both spawned processes run with a fully isolated environment (temporary
/// HOME, no XDG_* overrides, PATH restricted so optional external lookups
/// such as symbrain cannot resolve) and never send a valid percent — the only
/// tool call is the original invalid input, which must be rejected before any
/// hardware or privilege path is reached.
final class ChargeLimitIntegerOverflowE2ETests: XCTestCase {

    /// Bounded wait for every spawn/frame step (never unbounded).
    private let frameTimeout: TimeInterval = 30

    /// Per-test isolated HOME; ConfigPaths falls back under it because the
    /// environment carries no XDG_* overrides.
    private var isolatedHome: URL!

    /// Path to the built symcockpit binary (repo root `.build/debug/`).
    private var symcockpitBinary: String {
        productsDirectory.appendingPathComponent("symcockpit").path
    }

    /// The root package's build directory (where this test bundle lives).
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not locate the products directory — not running within an XCTest bundle?")
    }

    override func setUpWithError() throws {
        isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("charge-overflow-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: isolatedHome.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let isolatedHome {
            try? FileManager.default.removeItem(at: isolatedHome)
        }
    }

    // MARK: - Tests

    /// Original CLI input: must exit with the usage code (2) and a usage
    /// message instead of dying on SIGTRAP. No hardware path is reached.
    func testBatteryLimitSetUnrepresentablePercentExitsWithUsageCode() throws {
        let child = try launchTune(["battery-limit", "set", "9223372036854775807"])
        defer { child.cleanupIfRunning() }

        XCTAssertTrue(child.waitForExit(timeout: frameTimeout),
                      "CLI must terminate within \(frameTimeout)s")
        let stderr = child.stderrLines().joined(separator: "\n")
        XCTAssertEqual(child.exitCode, 2,
                       "unrepresentable percent must exit 2 (usage), got \(child.exitCode); stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("battery-limit"),
                      "expected a battery-limit usage message, got: \(stderr)")
        XCTAssertFalse(stderr.contains("Fatal error"),
                       "the conversion must not trap: \(stderr)")
    }

    /// Original MCP input: the tools/call must come back as a nonfatal
    /// JSON-RPC error, and the server must still answer the next ping.
    func testSetChargeLimitUnrepresentablePercentReturnsErrorAndServerAnswersNextPing() throws {
        let child = try launchTune(["serve"])
        defer { child.cleanupIfRunning() }

        // initialize → response with matching id, no error.
        try child.writeFrame(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let initEnvelope = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual((initEnvelope["id"] as? NSNumber)?.intValue, 1)
        XCTAssertNil(initEnvelope["error"], "initialize must not return an error")

        // ping → alive before the offending call.
        try child.writeFrame(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let pingEnvelope = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual((pingEnvelope["id"] as? NSNumber)?.intValue, 2)
        XCTAssertNil(pingEnvelope["error"])

        // The original issue #285 input: percent as a string.
        try child.writeFrame(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_charge_limit","arguments":{"percent":"9223372036854775807"}}}"#
        )
        let callEnvelope = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual((callEnvelope["id"] as? NSNumber)?.intValue, 3)
        XCTAssertNotNil(callEnvelope["error"],
                        "an unrepresentable percent must surface as a nonfatal MCP error, got: \(callEnvelope)")

        // Liveness: the server must still answer a subsequent ping.
        try child.writeFrame(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        let pingAgain = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual((pingAgain["id"] as? NSNumber)?.intValue, 4)
        XCTAssertNil(pingAgain["error"], "the server must stay healthy after the rejected call")
        XCTAssertNotNil(pingAgain["result"])

        // Zero stdout pollution: every stdout line is a JSON-RPC frame.
        for line in child.stdoutLines() {
            XCTAssertTrue(isJSONRPCFrame(line),
                          "stdout must contain only JSON-RPC frames, got: \(line)")
        }
    }

    // MARK: - Helpers

    /// Spawns `symcockpit tune <arguments>` with a fully explicit, isolated
    /// environment (setting `Process.environment` replaces the inherited one,
    /// so XDG_* overrides are absent by construction).
    private func launchTune(_ arguments: [String]) throws -> ServeChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: symcockpitBinary)
        process.arguments = ["tune"] + arguments
        process.environment = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path,
            "TMPDIR": isolatedHome.appendingPathComponent("tmp").path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let child = ServeChild(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        try child.start()
        return child
    }

    private func parseFrame(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            throw ServeTestError.unparseableFrame(line)
        }
        return dict
    }

    private func isJSONRPCFrame(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return false
        }
        return dict["jsonrpc"] as? String == "2.0"
    }
}

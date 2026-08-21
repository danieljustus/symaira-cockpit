import Foundation
import XCTest

/// Integration tests for the public `symtune serve` run path. The in-process
/// migration tests drive `TuneMCPServer.makeServer()` through pipes, but the
/// public bridge — the convenience-init default config load and `run()`'s
/// `MCPStdioTransport` launch, EOF termination, and start-failure propagation —
/// is only reachable by launching the real binary. These tests do exactly
/// that: a bounded subprocess speaking newline-delimited JSON-RPC over stdio
/// pipes, verifying initialize/ping framing, EOF termination, and the
/// zero-stdout-pollution contract.
final class SymTuneServeIntegrationTests: XCTestCase {

    /// Bounded wait for every framing/termination step (never unbounded).
    private let frameTimeout: TimeInterval = 30

    /// Path to the built symtune binary (SPM places it next to the .xctest bundle).
    var symtuneBinary: String {
        productsDirectory.appendingPathComponent("symtune").path
    }

    /// Returns the products directory (where the test bundle and symtune live).
    var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not locate the products directory — not running within an XCTest bundle?")
    }

    // MARK: - Tests

    func testServeInitializePingEOFAndStdoutPurity() throws {
        let child = try launchServe()
        defer { child.cleanupIfRunning() }

        // initialize → response with matching id and a result payload.
        try child.writeFrame(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let initEnvelope = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual(initEnvelope["jsonrpc"] as? String, "2.0")
        XCTAssertEqual((initEnvelope["id"] as? NSNumber)?.intValue, 1)
        XCTAssertNil(initEnvelope["error"], "initialize must not return an error")
        let initResult = try XCTUnwrap(initEnvelope["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(initResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "symtune")

        // ping → response with matching id and a result payload.
        try child.writeFrame(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let pingEnvelope = try parseFrame(child.waitForNextFrame(timeout: frameTimeout))
        XCTAssertEqual(pingEnvelope["jsonrpc"] as? String, "2.0")
        XCTAssertEqual((pingEnvelope["id"] as? NSNumber)?.intValue, 2)
        XCTAssertNil(pingEnvelope["error"], "ping must not return an error")
        XCTAssertNotNil(pingEnvelope["result"])

        // stdin EOF → run() returns and the process exits cleanly.
        child.closeStdin()
        XCTAssertTrue(child.waitForExit(timeout: frameTimeout),
                      "symtune serve did not exit within \(frameTimeout)s of stdin EOF")
        XCTAssertEqual(child.exitCode, 0, "serve should exit 0 after EOF termination")

        // Zero stdout pollution: every stdout line is a JSON-RPC frame.
        let stdoutLines = child.stdoutLines()
        XCTAssertFalse(stdoutLines.isEmpty,
                       "expected at least the initialize and ping responses on stdout")
        for line in stdoutLines {
            XCTAssertTrue(isJSONRPCFrame(line),
                          "stdout must contain only JSON-RPC frames, got: \(line)")
        }

        // Logs (if any) go to stderr — never as frames on stdout.
        for line in child.stderrLines() {
            XCTAssertFalse(isJSONRPCFrame(line),
                           "JSON-RPC frames must go to stdout, not stderr: \(line)")
        }
    }

    func testServeExitsZeroOnImmediateStdinEOF() throws {
        let child = try launchServe()
        defer { child.cleanupIfRunning() }

        // Closing stdin before any request must still end the server loop.
        child.closeStdin()
        XCTAssertTrue(child.waitForExit(timeout: frameTimeout),
                      "symtune serve did not exit within \(frameTimeout)s of immediate stdin EOF")
        XCTAssertEqual(child.exitCode, 0)
    }

    // MARK: - Helpers

    private func launchServe() throws -> ServeChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: symtuneBinary)
        process.arguments = ["serve"]

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
        guard let data = line.data(using: .utf8) else {
            throw ServeTestError.unparseableFrame(line)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            throw ServeTestError.unparseableFrame(line)
        }
        return dict
    }

    private func isJSONRPCFrame(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        guard let dict = object as? [String: Any],
              let version = dict["jsonrpc"] as? String
        else {
            return false
        }
        return version == "2.0"
    }
}

/// Bounded subprocess harness for `symtune serve`. Uses the
/// terminationHandler + semaphore pattern with a timeout — never
/// `waitUntilExit()`. On timeout the child is SIGTERM'd, then SIGKILL'd after
/// a short grace period so a hung server can never block the test run.
private final class ServeChild: @unchecked Sendable {
    private let process: Process
    private let stdin: FileHandle
    private let stdoutReader: LineAccumulator
    private let stderrReader: LineAccumulator
    private let terminated = DispatchSemaphore(value: 0)
    private var didCloseStdin = false

    init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.stdoutReader = LineAccumulator(handle: stdout)
        self.stderrReader = LineAccumulator(handle: stderr)
    }

    func start() throws {
        process.terminationHandler = { [weak self] _ in
            self?.terminated.signal()
        }
        stdoutReader.start()
        stderrReader.start()
        try process.run()
    }

    var exitCode: Int32 { process.terminationStatus }

    func writeFrame(_ frame: String) throws {
        var data = Data(frame.utf8)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    func closeStdin() {
        guard !didCloseStdin else { return }
        didCloseStdin = true
        try? stdin.close()
    }

    /// Blocks until the next stdout line arrives, bounded by `timeout`.
    func waitForNextFrame(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = stdoutReader.nextLine() {
                return line
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ServeTestError.timeoutWaitingForFrame
    }

    /// Bounded wait for process termination. On timeout the child is
    /// terminated and `false` is returned.
    func waitForExit(timeout: TimeInterval) -> Bool {
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            terminateHard()
            return false
        }
        // Grace: let the background readers observe the final EOF chunk.
        let deadline = Date().addingTimeInterval(2)
        while !stdoutReader.finished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    func stdoutLines() -> [String] { stdoutReader.allLines() }

    func stderrLines() -> [String] { stderrReader.allLines() }

    /// Ensures no child is left behind after a failed or timed-out test.
    func cleanupIfRunning() {
        guard process.isRunning else { return }
        terminateHard()
    }

    private func terminateHard() {
        process.terminate()
        _ = terminated.wait(timeout: .now() + 3)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Thread-safe accumulator of newline-delimited output, fed by a background
/// reader thread so the test never blocks on a pipe the child keeps open.
private final class LineAccumulator: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingLines: [String] = []
    private var recordedLines: [String] = []
    private var isFinished = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Starts a background thread that drains `handle` until EOF.
    func start() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while true {
                let chunk = self.handle.availableData
                if chunk.isEmpty {
                    self.appendChunk(chunk, eof: true)
                    break
                }
                self.appendChunk(chunk, eof: false)
            }
        }
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    /// Returns the next pending line, or nil if none is buffered yet.
    func nextLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingLines.isEmpty else { return nil }
        return pendingLines.removeFirst()
    }

    /// Every line seen since `start()` (for whole-stream assertions).
    func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLines
    }

    private func appendChunk(_ chunk: Data, eof: Bool) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let text = (String(data: lineData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                record(text)
            }
        }
        if eof {
            if !buffer.isEmpty {
                let text = (String(data: buffer, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    record(text)
                }
                buffer.removeAll(keepingCapacity: true)
            }
            isFinished = true
        }
    }

    private func record(_ line: String) {
        pendingLines.append(line)
        recordedLines.append(line)
    }
}

private enum ServeTestError: Error, CustomStringConvertible {
    case timeoutWaitingForFrame
    case unparseableFrame(String)

    var description: String {
        switch self {
        case .timeoutWaitingForFrame:
            return "Timed out waiting for a JSON-RPC frame on stdout"
        case let .unparseableFrame(line):
            return "Stdout line is not a JSON-RPC object: \(line)"
        }
    }
}

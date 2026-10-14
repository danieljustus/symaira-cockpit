import Foundation
import XCTest

final class WatchCancellationE2ETests: XCTestCase {
    /// The read-only watch must handle Ctrl-C and SIGTERM during its wait,
    /// rather than waiting for the next (potentially hour-long) sample.
    func testWatchExitsOnSignalsBetweenSamples() throws {
        try assertInterrupt(arguments: ["status", "--watch", "--interval", "60s"], readinessMessage: nil)
    }

    /// Creates only a short-lived idle-sleep assertion in the owned child.
    func testTimedAwakeExitsOnSignalsDuringWait() throws {
        try assertInterrupt(arguments: ["awake", "--seconds", "60"], readinessMessage: "holding wake assertion")
    }

    private func assertInterrupt(arguments: [String], readinessMessage: String?) throws {
        for signalNumber in [SIGINT, SIGTERM] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
            let process = Process()
            process.executableURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("symcockpit")
            process.arguments = arguments
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": directory.path,
                "CFFIXED_USER_HOME": directory.path,
                "XDG_CONFIG_HOME": directory.appendingPathComponent("config").path,
                "XDG_DATA_HOME": directory.appendingPathComponent("data").path,
            ]
            let output = directory.appendingPathComponent("stdout.jsonl")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            defer {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 3)
                }
            }
            let readinessDeadline = Date(timeIntervalSinceNow: 10)
            var firstReport: [String: Any]?
            var ready = false
            while !ready, process.isRunning, Date() < readinessDeadline {
                let text = try String(contentsOf: output, encoding: .utf8)
                if let readinessMessage { ready = text.contains(readinessMessage) }
                for line in text.split(separator: "\n") {
                    firstReport = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    if firstReport?["health_score"] != nil { ready = true; break }
                }
                if !ready { Thread.sleep(forTimeInterval: 0.02) }
            }
            XCTAssertTrue(ready, "command must reach its wait before signaling")
            XCTAssertTrue(process.isRunning)
            guard process.isRunning else { continue }
            XCTAssertEqual(kill(process.processIdentifier, signalNumber), 0)
            let result = exited.wait(timeout: .now() + 3)
            XCTAssertEqual(result, .success, "signal \(signalNumber) must interrupt the 60-second wait")
            if result == .success { XCTAssertEqual(process.terminationStatus, 0) }
        }
    }
}

import Darwin
import Foundation

/// The outcome of a subprocess that was given a finite execution budget.
public struct BoundedProcessResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(standardOutput: Data, standardError: Data, terminationStatus: Int32, timedOut: Bool) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }

    public var output: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }
}

public enum BoundedProcessRunner {
    /// Runs a child for at most `timeoutSeconds`, terminating it when the
    /// deadline expires. A short SIGTERM grace period is followed by SIGKILL
    /// so a wedged executable cannot keep a caller blocked indefinitely.
    public static func run(
        executable: String,
        arguments: [String] = [],
        timeoutSeconds: TimeInterval = 3
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            waitUntilStopped(process, before: Date().addingTimeInterval(0.25))
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                waitUntilStopped(process, before: Date().addingTimeInterval(0.25))
            }
        }

        // All direct children have been stopped before reading to EOF. This
        // avoids the unbounded pipe read that made the old call sites hang.
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return BoundedProcessResult(
            standardOutput: output,
            standardError: error,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func waitUntilStopped(_ process: Process, before deadline: Date) {
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
    }
}

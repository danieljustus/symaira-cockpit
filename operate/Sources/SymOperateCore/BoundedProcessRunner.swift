import Darwin
import Foundation

struct BoundedAppProcessResult: Sendable {
    let terminationStatus: Int32
    let timedOut: Bool
}

enum BoundedAppProcessRunner {
    static func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval) throws -> BoundedAppProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
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
        return BoundedAppProcessResult(terminationStatus: process.terminationStatus, timedOut: timedOut)
    }

    private static func waitUntilStopped(_ process: Process, before deadline: Date) {
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
    }
}

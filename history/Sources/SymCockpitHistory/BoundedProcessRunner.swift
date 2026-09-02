import Darwin
import Dispatch
import Foundation

/// The outcome of a subprocess that was given a finite execution budget.
public struct BoundedProcessResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(
        standardOutput: Data,
        standardError: Data,
        terminationStatus: Int32,
        timedOut: Bool
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }

    public var output: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }
}

public enum BoundedProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable(String)
    case standardInputWriteFailed

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let executable):
            return "Executable not found or not executable: \(executable)"
        case .standardInputWriteFailed:
            return "Could not write subprocess standard input"
        }
    }
}

/// Runs local commands with bounded lifetime and captured output.
///
/// A bare executable name is resolved only against the supplied environment's
/// `PATH`; no shell or user-specific fallback path is used. Absolute paths are
/// accepted for callers that already own a system path. Output is read after
/// the child has stopped. Concurrent pipe draining is intentionally outside
/// this foundation's scope so a later runner hardening can preserve this API.
public enum BoundedProcessRunner {
    public static func run(
        executable: String,
        arguments: [String] = [],
        timeoutSeconds: TimeInterval = 3,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: Data? = nil
    ) throws -> BoundedProcessResult {
        guard let executablePath = resolve(executable, environment: environment) else {
            throw BoundedProcessRunnerError.executableUnavailable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw BoundedProcessRunnerError.executableUnavailable(executable)
        }
        let processGroupID = process.processIdentifier
        let hasDedicatedProcessGroup = setpgid(processGroupID, processGroupID) == 0

        do {
            if let standardInput {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            terminateAndReap(process, processGroupID: processGroupID, hasDedicatedProcessGroup: hasDedicatedProcessGroup)
            throw BoundedProcessRunnerError.standardInputWriteFailed
        }

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            terminateAndReap(process, processGroupID: processGroupID, hasDedicatedProcessGroup: hasDedicatedProcessGroup)
        } else {
            // waitUntilExit is also the explicit reap for naturally completed
            // children; polling is not a substitute for collecting the status.
            process.waitUntilExit()
        }

        // This intentionally remains a post-exit read. Concurrent draining is
        // issue #159 and must be introduced without changing this API. A timed
        // out command may have descendants holding the inherited pipe open, so
        // take only the bytes currently available instead of waiting for EOF.
        let output = timedOut
            ? readAvailableData(from: outputPipe.fileHandleForReading)
            : outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = timedOut
            ? readAvailableData(from: errorPipe.fileHandleForReading)
            : errorPipe.fileHandleForReading.readDataToEndOfFile()
        return BoundedProcessResult(
            standardOutput: output,
            standardError: error,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }

    public static func runAsync(
        executable: String,
        arguments: [String] = [],
        timeoutSeconds: TimeInterval = 3,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: Data? = nil
    ) async throws -> BoundedProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try run(
                        executable: executable,
                        arguments: arguments,
                        timeoutSeconds: timeoutSeconds,
                        environment: environment,
                        standardInput: standardInput
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func resolve(_ executable: String, environment: [String: String]) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func terminateAndReap(
        _ process: Process,
        processGroupID: Int32,
        hasDedicatedProcessGroup: Bool
    ) {
        if process.isRunning {
            process.terminate()
            waitUntilStopped(process, before: Date().addingTimeInterval(0.25))
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            if hasDedicatedProcessGroup {
                _ = kill(-processGroupID, SIGKILL)
            }
        }
        // The child is guaranteed to have been signalled before waiting. This
        // collects it instead of leaving a zombie behind after a timeout.
        process.waitUntilExit()
    }

    private static func waitUntilStopped(_ process: Process, before deadline: Date) {
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
    }

    private static func readAvailableData(from handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return Data() }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }
}

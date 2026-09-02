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
/// accepted for callers that already own a system path. Standard output and
/// standard error are drained concurrently while the child is running.
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

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw BoundedProcessRunnerError.executableUnavailable(executable)
        }
        let processGroupID = process.processIdentifier
        let hasDedicatedProcessGroup = setpgid(processGroupID, processGroupID) == 0

        let outputCollector = DataCollector()
        let errorCollector = DataCollector()
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        readerGroup.enter()

        // Register both readers immediately after launch. A child can fill
        // either pipe while it is still running, so post-exit reads can deadlock.
        let outputReader = PipeReader(
            handle: outputPipe.fileHandleForReading,
            collector: outputCollector,
            completion: readerGroup
        )
        let errorReader = PipeReader(
            handle: errorPipe.fileHandleForReading,
            collector: errorCollector,
            completion: readerGroup
        )

        do {
            if let standardInput {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            terminateAndReap(
                process,
                processGroupID: processGroupID,
                hasDedicatedProcessGroup: hasDedicatedProcessGroup,
                terminationSemaphore: terminationSemaphore
            )
            waitForReaders(
                readerGroup,
                outputReader: outputReader,
                errorReader: errorReader
            )
            throw BoundedProcessRunnerError.standardInputWriteFailed
        }

        let waitResult = terminationSemaphore.wait(timeout: .now() + max(0, timeoutSeconds))
        let timedOut = waitResult == .timedOut
        if timedOut {
            terminateAndReap(
                process,
                processGroupID: processGroupID,
                hasDedicatedProcessGroup: hasDedicatedProcessGroup,
                terminationSemaphore: terminationSemaphore
            )
        } else {
            // waitUntilExit is the explicit reap for naturally completed
            // children; the termination handler only provides bounded waiting.
            process.waitUntilExit()
        }
        process.terminationHandler = nil

        // On timeout the process group is gone before waiting for EOF, so all
        // inherited pipe writers have been closed and both readers can finish.
        waitForReaders(
            readerGroup,
            outputReader: outputReader,
            errorReader: errorReader,
            timeout: timedOut ? .milliseconds(100) : .milliseconds(500)
        )
        return BoundedProcessResult(
            standardOutput: outputCollector.value,
            standardError: errorCollector.value,
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
        hasDedicatedProcessGroup: Bool,
        terminationSemaphore: DispatchSemaphore
    ) {
        process.terminate()
        if terminationSemaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            _ = kill(process.processIdentifier, SIGKILL)
            if hasDedicatedProcessGroup {
                _ = kill(-processGroupID, SIGKILL)
            }
        }
        // The child is guaranteed to have been signalled before waiting. This
        // collects it instead of leaving a zombie behind after a timeout.
        process.waitUntilExit()
    }

    private static func waitForReaders(
        _ readerGroup: DispatchGroup,
        outputReader: PipeReader,
        errorReader: PipeReader,
        timeout: DispatchTimeInterval = .milliseconds(500)
    ) {
        guard readerGroup.wait(timeout: .now() + timeout) == .timedOut else {
            return
        }
        // A failed process-group setup can leave an inherited writer alive.
        // Stop handlers after the bounded grace period rather than hanging the
        // runner indefinitely; bytes already delivered remain captured.
        outputReader.cancel()
        errorReader.cancel()
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ data: Data) {
        lock.lock()
        self.data.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let collector: DataCollector
    private let completion: DispatchGroup
    private let stateLock = NSLock()
    private var finished = false

    init(handle: FileHandle, collector: DataCollector, completion: DispatchGroup) {
        self.handle = handle
        self.collector = collector
        self.completion = completion
        handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle)
        }
    }

    private func consume(_ handle: FileHandle) {
        stateLock.lock()
        let isFinished = finished
        stateLock.unlock()
        guard !isFinished else { return }

        let data = handle.availableData
        if !data.isEmpty {
            collector.append(data)
            return
        }

        finish(handle: handle)
    }

    private func finish(handle: FileHandle) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        stateLock.unlock()

        handle.readabilityHandler = nil
        completion.leave()
    }

    func cancel() {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        stateLock.unlock()

        handle.readabilityHandler = nil
        completion.leave()
    }
}

import Foundation

// Client of the Cockpit 2 app agent (`symcockpit agent --stdio`, wire format in
// docs/agent-protocol.md). It lives in SymCockpitCore because the GUI owns no
// logic (AGENTS.md): the window reads this class and the agent's answers, and
// both the menu-bar popover and the cockpit window can embed it. It is
// Foundation-only, so tests run it against a fake agent without AppKit.
//
// The agent is a child process: stdin/stdout carry one JSON-RPC 2.0 message per
// line, stderr is diagnostics. This class never invents a value: when the agent
// is missing, refuses to start, speaks another protocol version or dies, the
// state is `.failed` with the reason and every pending request fails with it.
// There is no automatic restart, so a crash loop cannot hide; the caller decides
// when to call `restart()` (and re-subscribes, because subscriptions belong to
// the agent process).

// MARK: - JSON

/// A JSON document, `Sendable` and `Equatable`, for params and results that
/// the app passes through without a model of its own.
public enum AgentJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSON])
    case object([String: AgentJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AgentJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> AgentJSON? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 {
            return Int(value)
        }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [AgentJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

// MARK: - Values the protocol returns

public struct AgentCommandInfo: Equatable, Sendable {
    public let name: String
    /// `read`, `reversible`, `risky` or `human_only`.
    public let risk: String
    public let inputSchema: AgentJSON
}

/// The agent's answer to `hello`.
public struct AgentHello: Equatable, Sendable {
    public let protocolVersion: Int
    public let serverVersion: String
    public let commands: [AgentCommandInfo]
    /// Commands `subscribe` accepts.
    public let topics: [String]
    /// Protocol methods this agent serves (`capabilities.methods`), host methods such as
    /// `clipboard.list` included when the agent hosts services.
    public let methods: [String]
    public let minIntervalMs: Int
    public let maxIntervalMs: Int
    public let defaultVisibleMs: Int
    public let defaultHiddenMs: Int

    init(json: AgentJSON) throws {
        guard let version = json["protocol_version"]?.intValue,
              let server = json["server_version"]?.stringValue,
              let commands = json["commands"]?.arrayValue,
              let capabilities = json["capabilities"],
              let topics = capabilities["topics"]?.arrayValue,
              let minInterval = capabilities["min_interval_ms"]?.intValue,
              let maxInterval = capabilities["max_interval_ms"]?.intValue,
              let visible = capabilities["default_interval_visible_ms"]?.intValue,
              let hidden = capabilities["default_interval_hidden_ms"]?.intValue
        else {
            throw AgentFailure.protocolViolation("the hello answer is incomplete")
        }
        self.protocolVersion = version
        self.serverVersion = server
        self.commands = commands.compactMap { entry in
            guard let name = entry["name"]?.stringValue, let risk = entry["risk"]?.stringValue else {
                return nil
            }
            return AgentCommandInfo(name: name, risk: risk, inputSchema: entry["input_schema"] ?? .null)
        }
        self.topics = topics.compactMap(\.stringValue)
        self.methods = (capabilities["methods"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.minIntervalMs = minInterval
        self.maxIntervalMs = maxInterval
        self.defaultVisibleMs = visible
        self.defaultHiddenMs = hidden
    }
}

/// What `call` returns: a risky command is only planned until `confirm`.
public enum AgentCallResult: Equatable, Sendable {
    case ok(command: String, risk: String, output: AgentJSON)
    case confirmationRequired(command: String, planID: String, plan: AgentJSON)
}

/// One sampled value (or failed sample) of a subscription.
public struct AgentEvent: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case result(AgentJSON)
        case error(AgentRemoteError)
    }

    public let subscriptionID: Int
    public let command: String
    public let sequence: Int
    /// Milliseconds on the agent's monotonic clock since it started.
    public let monotonicMs: Int
    public let payload: Payload
    /// The agent removed the subscription after this event.
    public let ended: Bool
}

// MARK: - Errors

/// The agent answered a request with a JSON-RPC error.
public struct AgentRemoteError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int
    public let message: String
    /// For a failed command: `usage`, `permission`, `unsupported` or `error`.
    public let exitClass: String?
    /// For a failed command: the CLI exit code (2 usage, 3 permission, 4 unsupported).
    public let exitCode: Int?
    /// The error's `data`, e.g. `supported` for a version mismatch.
    public let data: AgentJSON?

    public var errorDescription: String? { message }

    init(json: AgentJSON?) {
        self.code = json?["code"]?.intValue ?? 0
        self.message = json?["message"]?.stringValue ?? "the agent reported an error without a message"
        self.exitClass = json?["data"]?["class"]?.stringValue
        self.exitCode = json?["data"]?["exit_code"]?.intValue
        self.data = json?["data"]
    }
}

/// Why the agent is not usable. Each case has a complete, honest description.
public enum AgentFailure: Error, Equatable, Sendable, LocalizedError {
    /// No executable at the path.
    case executableMissing(path: String)
    case launchFailed(String)
    /// The agent speaks other protocol versions than this client.
    case versionMismatch(clientVersion: Int, agentVersions: [Int])
    /// The agent printed something that is not protocol.
    case protocolViolation(String)
    /// The process ended. `stderr` is the end of its diagnostics.
    case exited(status: Int32, stderr: String)
    case timedOut(String)
    /// A request needs a running agent.
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "The Cockpit agent is missing: no executable at \(path)."
        case .launchFailed(let reason):
            return "The Cockpit agent could not be started: \(reason)"
        case .versionMismatch(let client, let agent):
            let versions = agent.map(String.init).joined(separator: ", ")
            return "The Cockpit agent speaks protocol version \(versions); this app needs \(client)."
        case .protocolViolation(let reason):
            return "The Cockpit agent broke the protocol: \(reason)"
        case .exited(let status, let stderr):
            let detail = stderr.isEmpty ? "" : " (\(stderr))"
            if status == 3 {
                return "The Cockpit agent refused to start because its parent is not the signed Symaira Cockpit app" + detail
            }
            return "The Cockpit agent exited with status \(status)" + detail
        case .timedOut(let what):
            return "The Cockpit agent did not answer \(what) in time."
        case .notRunning:
            return "The Cockpit agent is not running."
        }
    }
}

public enum AgentState: Equatable, Sendable {
    case stopped
    case starting
    case ready(AgentHello)
    case failed(AgentFailure)
}

// MARK: - Client

public final class AgentClient: @unchecked Sendable {
    /// The protocol version this client speaks (`PROTOCOL_VERSION` in the Rust contract).
    public static let protocolVersion = 1

    public struct Configuration: Sendable {
        public var executable: URL
        public var arguments: [String]
        /// `nil` inherits the app's environment.
        public var environment: [String: String]?
        public var clientName: String
        /// How long `hello` may take, process launch included.
        public var startTimeout: TimeInterval
        public var requestTimeout: TimeInterval

        public init(
            executable: URL,
            arguments: [String] = ["agent", "--stdio"],
            environment: [String: String]? = nil,
            clientName: String = "symcockpit-app",
            startTimeout: TimeInterval = 10,
            requestTimeout: TimeInterval = 30
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.clientName = clientName
            self.startTimeout = startTimeout
            self.requestTimeout = requestTimeout
        }
    }

    private struct Pending {
        let continuation: CheckedContinuation<AgentJSON, Error>
        let timer: Task<Void, Never>
    }

    private let configuration: Configuration
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onStateChange: @Sendable (AgentState) -> Void

    private let lock = NSLock()
    private var currentState: AgentState = .stopped
    private var process: Process?
    private var stdin: FileHandle?
    private var generation = 0
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var lineBuffer = Data()
    private var stderrTail = Data()
    private var stopping = false

    /// `onEvent` and `onStateChange` run on background threads, never while the
    /// client holds a lock.
    public init(
        configuration: Configuration,
        onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in },
        onStateChange: @escaping @Sendable (AgentState) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onEvent = onEvent
        self.onStateChange = onStateChange
    }

    deinit { stop() }

    public var state: AgentState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    // MARK: Lifecycle

    /// Launches the agent and completes the handshake. Returns the agent's
    /// answer; throws an `AgentFailure` and leaves the state `.failed`.
    @discardableResult
    public func start() async throws -> AgentHello {
        if case .ready(let hello) = state { return hello }
        try launch()
        do {
            let answer = try await request(
                "hello",
                params: .object([
                    "protocol_version": .number(Double(Self.protocolVersion)),
                    "client": .string(configuration.clientName),
                ]),
                timeout: configuration.startTimeout
            )
            let hello = try AgentHello(json: answer)
            guard hello.protocolVersion == Self.protocolVersion else {
                throw AgentFailure.versionMismatch(
                    clientVersion: Self.protocolVersion, agentVersions: [hello.protocolVersion]
                )
            }
            setState(.ready(hello))
            return hello
        } catch {
            let failure = Self.failure(from: error)
            fail(failure)
            throw failure
        }
    }

    /// Stops the agent (if running) and starts a new one. Subscriptions of the
    /// old process are gone; subscribe again after this returns.
    @discardableResult
    public func restart() async throws -> AgentHello {
        stop()
        return try await start()
    }

    /// Closes stdin, which ends the agent cleanly, and terminates it if it has
    /// not exited after two seconds.
    public func stop() {
        lock.lock()
        stopping = true
        let process = self.process
        let stdin = self.stdin
        self.process = nil
        self.stdin = nil
        let orphaned = pending
        pending = [:]
        lock.unlock()
        for entry in orphaned.values {
            entry.timer.cancel()
            entry.continuation.resume(throwing: AgentFailure.notRunning)
        }
        try? stdin?.close()
        if let process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
        setState(.stopped)
    }

    // MARK: Requests

    /// Runs a register command. A `risky` one returns `.confirmationRequired`;
    /// show the plan to the user and call `confirm(planID:)` on approval.
    public func call(_ command: String, params: [String: AgentJSON] = [:]) async throws -> AgentCallResult {
        let result = try await request(
            "call",
            params: .object(["command": .string(command), "params": .object(params)]),
            timeout: configuration.requestTimeout
        )
        guard let status = result["status"]?.stringValue,
              let name = result["command"]?.stringValue
        else {
            throw AgentFailure.protocolViolation("the call answer has no status")
        }
        switch status {
        case "ok":
            return .ok(
                command: name, risk: result["risk"]?.stringValue ?? "",
                output: result["output"] ?? .null
            )
        case "confirmation_required":
            guard let plan = result["plan"], let id = plan["id"]?.stringValue else {
                throw AgentFailure.protocolViolation("the plan has no id")
            }
            return .confirmationRequired(command: name, planID: id, plan: plan)
        default:
            throw AgentFailure.protocolViolation("unknown call status '\(status)'")
        }
    }

    /// Executes a plan the user approved. The result carries `status`
    /// (`confirmed`, `failed`, `unsupported` ...), `results` and the command's
    /// `output` or `error`.
    public func confirm(planID: String) async throws -> AgentJSON {
        try await request(
            "confirm", params: .object(["plan_id": .string(planID)]),
            timeout: configuration.requestTimeout
        )
    }

    /// An agent method that is not a register command (`HOST_METHODS`: `clipboard.*`, `services`).
    public func invoke(_ method: String, params: [String: AgentJSON] = [:]) async throws -> AgentJSON {
        try await request(method, params: .object(params), timeout: configuration.requestTimeout)
    }

    /// Starts sampling `command`; events arrive through `onEvent`. Intervals
    /// default to the agent's (1 s visible, 10 s hidden). Returns the id.
    public func subscribe(
        _ command: String, params: [String: AgentJSON] = [:],
        visibleMs: Int? = nil, hiddenMs: Int? = nil
    ) async throws -> Int {
        var body: [String: AgentJSON] = ["command": .string(command), "params": .object(params)]
        if let visibleMs { body["interval_visible_ms"] = .number(Double(visibleMs)) }
        if let hiddenMs { body["interval_hidden_ms"] = .number(Double(hiddenMs)) }
        let result = try await request("subscribe", params: .object(body), timeout: configuration.requestTimeout)
        guard let id = result["subscription_id"]?.intValue else {
            throw AgentFailure.protocolViolation("the subscribe answer has no subscription_id")
        }
        return id
    }

    public func unsubscribe(_ subscriptionID: Int) async throws {
        _ = try await request(
            "unsubscribe", params: .object(["subscription_id": .number(Double(subscriptionID))]),
            timeout: configuration.requestTimeout
        )
    }

    /// Tells the agent whether a view that needs measurements is on screen:
    /// hidden slows every subscription to its hidden interval.
    public func setVisibility(_ visible: Bool) async throws {
        _ = try await request(
            "set_visibility", params: .object(["visible": .bool(visible)]),
            timeout: configuration.requestTimeout
        )
    }

    // MARK: Process

    private func launch() throws {
        let path = configuration.executable.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let failure = AgentFailure.executableMissing(path: path)
            setState(.failed(failure))
            throw failure
        }
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        if let environment = configuration.environment { process.environment = environment }
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A write to an agent that already died must be an error, not SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        lock.lock()
        generation += 1
        let mine = generation
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        lineBuffer = Data()
        stderrTail = Data()
        stopping = false
        lock.unlock()
        setState(.starting)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.feed(stdout: data, generation: mine)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.feed(stderr: data, generation: mine)
            }
        }
        process.terminationHandler = { [weak self] finished in
            // The pipes can still hold the last output.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? stderrPipe.fileHandleForReading.readToEnd() {
                self?.feed(stderr: rest, generation: mine)
            }
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd() {
                self?.feed(stdout: rest, generation: mine)
            }
            self?.exited(status: finished.terminationStatus, generation: mine)
        }
        do {
            try process.run()
        } catch {
            let failure = AgentFailure.launchFailed(error.localizedDescription)
            fail(failure)
            throw failure
        }
    }

    private func exited(status: Int32, generation mine: Int) {
        lock.lock()
        guard mine == generation, !stopping else {
            lock.unlock()
            return
        }
        let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        fail(.exited(status: status, stderr: tail))
    }

    /// Records the failure, fails every pending request with it and ends the process.
    private func fail(_ failure: AgentFailure) {
        lock.lock()
        if case .failed = currentState, process == nil {
            lock.unlock()
            return
        }
        let process = self.process
        let stdin = self.stdin
        self.process = nil
        self.stdin = nil
        let orphaned = pending
        pending = [:]
        lock.unlock()
        for entry in orphaned.values {
            entry.timer.cancel()
            entry.continuation.resume(throwing: failure)
        }
        try? stdin?.close()
        if let process, process.isRunning { process.terminate() }
        setState(.failed(failure))
    }

    private static func failure(from error: Error) -> AgentFailure {
        if let failure = error as? AgentFailure { return failure }
        if let remote = error as? AgentRemoteError {
            if remote.code == -32010 {
                let supported = remote.data?["supported"]?.arrayValue?.compactMap(\.intValue) ?? []
                return .versionMismatch(clientVersion: protocolVersion, agentVersions: supported)
            }
            return .protocolViolation("hello was refused: \(remote.message)")
        }
        return .protocolViolation(error.localizedDescription)
    }

    // MARK: Wire

    private func request(_ method: String, params: AgentJSON, timeout: TimeInterval) async throws -> AgentJSON {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let stdin, process != nil else {
                lock.unlock()
                continuation.resume(throwing: AgentFailure.notRunning)
                return
            }
            let id = nextID
            nextID += 1
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(id, .failure(AgentFailure.timedOut(method)))
            }
            pending[id] = Pending(continuation: continuation, timer: timer)
            lock.unlock()
            let frame = AgentJSON.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string(method), "params": params,
            ])
            do {
                var line = try JSONEncoder().encode(frame)
                line.append(0x0A)
                try stdin.write(contentsOf: line)
            } catch {
                resolve(id, .failure(AgentFailure.notRunning))
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<AgentJSON, Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }

    private func feed(stderr data: Data, generation mine: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard mine == generation else { return }
        stderrTail.append(data)
        if stderrTail.count > 2048 { stderrTail = stderrTail.suffix(2048) }
    }

    private func feed(stdout data: Data, generation mine: Int) {
        lock.lock()
        guard mine == generation else {
            lock.unlock()
            return
        }
        lineBuffer.append(data)
        var lines: [Data] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(Data(lineBuffer[lineBuffer.startIndex..<newline]))
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line: line) }
    }

    private func handle(line: Data) {
        guard let frame = try? JSONDecoder().decode(AgentJSON.self, from: line),
              case .object = frame
        else {
            let preview = String(decoding: line.prefix(80), as: UTF8.self)
            fail(.protocolViolation("stdout carried a line that is not a JSON object: \(preview)"))
            return
        }
        if let id = frame["id"]?.intValue, frame["method"] == nil {
            if let error = frame["error"] {
                resolve(id, .failure(AgentRemoteError(json: error)))
            } else {
                resolve(id, .success(frame["result"] ?? .null))
            }
        } else if frame["method"]?.stringValue == "event", let event = Self.event(from: frame["params"]) {
            onEvent(event)
        }
        // Other notifications are ignored: a newer agent may send more.
    }

    private static func event(from params: AgentJSON?) -> AgentEvent? {
        guard let params,
              let id = params["subscription_id"]?.intValue,
              let command = params["command"]?.stringValue,
              let sequence = params["seq"]?.intValue,
              let monotonic = params["monotonic_ms"]?.intValue
        else { return nil }
        let payload: AgentEvent.Payload
        if let error = params["error"] {
            payload = .error(AgentRemoteError(json: error))
        } else if let result = params["result"] {
            payload = .result(result)
        } else {
            return nil
        }
        return AgentEvent(
            subscriptionID: id, command: command, sequence: sequence, monotonicMs: monotonic,
            payload: payload, ended: params["ended"]?.boolValue ?? false
        )
    }

    private func setState(_ state: AgentState) {
        lock.lock()
        let changed = currentState != state
        currentState = state
        lock.unlock()
        if changed { onStateChange(state) }
    }
}

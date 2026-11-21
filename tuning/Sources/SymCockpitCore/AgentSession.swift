import Foundation

// The app-wide session with the Cockpit 2 agent (`symcockpit agent --stdio`,
// docs/agent-protocol.md). One process per app run: started at launch, ended
// by closing its stdin at quit. Every view model of the app reads through this
// class and acts through it; none of them owns a hardware controller.
//
// What the session adds on top of `AgentClient`:
// - the lifecycle in one place (`start`, `restart`, `stop`) with a state the UI
//   shows as a diagnosis, never a made-up value;
// - subscriptions that belong to the app, not to the process: they are
//   re-established after a restart, and an event that arrives before the
//   subscribe answer was processed is held back, not lost;
// - `set_visibility` derived from the views that report themselves visible
//   (1 s while one is, 10 s otherwise); a subscription only exists while its
//   view needs it, so with nothing subscribed the agent measures nothing (Q04);
// - actions as `ActionOutcome`: reversible ones just run, a risky one comes
//   back as a plan the user confirms (`confirm`) in the app.
//
// Foundation-only, so tests run it against the Perl fake agent.

// MARK: - Decoding

public enum AgentDecoding {
    /// The agent prints the same JSON as the CLI: snake_case keys. A few Swift
    /// properties spell an acronym in capitals (`displayID`, `maxEDRHeadroom`,
    /// `ProviderResult.providerID`), which `.convertFromSnakeCase` cannot
    /// produce, so those keys are mapped here (shortcut: by key name; upgrade
    /// when those types get explicit coding keys).
    public static func decode<T: Decodable>(_ type: T.Type, from json: AgentJSON) throws -> T {
        let data = try JSONEncoder().encode(json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!
            if key.intValue != nil { return key }
            var camel = camelCase(key.stringValue)
            if let capitals = acronymKeys[camel] {
                camel = capitals
            } else if camel == "providerId", path.dropLast().last?.intValue != nil {
                // A provider result (array element); the snapshot inside it keeps `providerId`.
                camel = "providerID"
            }
            return AnyKey(camel)
        }
        return try decoder.decode(type, from: data)
    }

    private static let acronymKeys = [
        "displayId": "displayID",
        "maxEdrHeadroom": "maxEDRHeadroom",
        "potentialEdrHeadroom": "potentialEDRHeadroom",
    ]

    static func camelCase(_ snake: String) -> String {
        let parts = snake.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count > 1, let first = parts.first else { return snake }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Plans and outcomes

/// A recorded plan of a risky command (`confirmation_required`): what the app
/// shows before the user approves it.
public struct AgentPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let command: String
        public let target: String
        public let params: AgentJSON
    }

    public let id: String
    public let command: String
    public let items: [Item]
    /// Seconds the plan stays valid after it was recorded.
    public let expiresInSeconds: Int?

    init(command: String, planID: String, plan: AgentJSON) {
        self.id = planID
        self.command = command
        self.expiresInSeconds = plan["expires_in_s"]?.intValue
        self.items = (plan["items"]?.arrayValue ?? []).map {
            Item(
                command: $0["command"]?.stringValue ?? command,
                target: $0["target"]?.stringValue ?? command,
                params: $0["params"] ?? .null
            )
        }
    }
}

/// The result of an action the app asked for.
public enum ActionOutcome: Equatable, Sendable {
    /// Ran (a reversible command) or was confirmed and succeeded.
    case done(AgentJSON)
    /// A risky command: nothing ran yet. Show the plan, then `confirm`.
    case needsConfirmation(AgentPlan)
    /// Failed with the agent's message (what the CLI would print) and its exit
    /// class (`usage`, `permission`, `unsupported`, `error`) when it has one.
    case failed(message: String, exitClass: String?)

    public var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

// MARK: - Session

public final class AgentSession: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentEvent) -> Void
    public typealias StateObserver = @Sendable (AgentState) -> Void

    private struct Desired {
        let command: String
        let params: [String: AgentJSON]
        let visibleMs: Int?
        let hiddenMs: Int?
        let handler: Handler
        var agentID: Int?
        /// The agent ended it (a capability this Mac does not have); not retried until a restart.
        var ended = false
    }

    private let lock = NSLock()
    // Set once in `init`, before the first use.
    private var client: AgentClient!
    private var desired: [UUID: Desired] = [:]
    private var byAgentID: [Int: UUID] = [:]
    private var early: [Int: [AgentEvent]] = [:]
    private var visibleOwners: Set<String> = []
    private var visibleAtAgent = true
    private var observers: [UUID: StateObserver] = [:]
    private var tail: Task<Void, Never>?
    /// Handlers run here, in the order the agent sent the events.
    private let deliveryQueue = DispatchQueue(label: "com.symaira.cockpit.agent-session.events")

    public init(configuration: AgentClient.Configuration) {
        client = AgentClient(
            configuration: configuration,
            onEvent: { [weak self] in self?.route($0) },
            onStateChange: { [weak self] in self?.stateChanged($0) }
        )
    }

    /// The session for an app bundle: the agent is `symcockpit` next to the
    /// app's own executable (`Contents/MacOS`).
    public static func bundled(bundle: Bundle = .main) -> AgentSession {
        let directory = bundle.executableURL?.deletingLastPathComponent() ?? bundle.bundleURL
        return AgentSession(configuration: .init(executable: directory.appendingPathComponent("symcockpit")))
    }

    deinit { client.stop() }

    public var state: AgentState { client.state }

    /// The hello answer while the agent is ready.
    public var hello: AgentHello? {
        if case .ready(let hello) = client.state { return hello }
        return nil
    }

    /// Observers run on background threads.
    @discardableResult
    public func addStateObserver(_ observer: @escaping StateObserver) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    public func removeStateObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    // MARK: Lifecycle

    /// Starts the agent. A failure is not thrown: it is the state
    /// (`.failed(...)`), which the UI shows as a diagnosis with a restart button.
    public func start() async {
        guard case .stopped = state else { return }
        await bringUp { try await self.client.start() }
    }

    /// Manual restart after a failure (or on demand): a new process, the same
    /// subscriptions.
    public func restart() async {
        await bringUp { try await self.client.restart() }
    }

    /// Ends the agent cleanly (stdin closed) at the end of the app.
    public func stop() {
        client.stop()
    }

    private func bringUp(_ launch: @Sendable () async throws -> AgentHello) async {
        do {
            _ = try await launch()
        } catch {
            return // the state already carries the failure
        }
        enqueue { await self.resynchronize() }
        await settled()
    }

    private func stateChanged(_ state: AgentState) {
        if case .ready = state {} else {
            lock.lock()
            for key in desired.keys {
                desired[key]?.agentID = nil
                desired[key]?.ended = false
            }
            byAgentID = [:]
            early = [:]
            visibleAtAgent = true // a new process starts visible
            lock.unlock()
        }
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer(state) }
    }

    // MARK: Subscriptions

    /// Samples `command` for as long as the returned token is not cancelled.
    /// The subscription is kept across agent restarts. A subscription the agent
    /// refuses reaches `handler` as one error event.
    public func subscribe(
        _ command: String, params: [String: AgentJSON] = [:],
        visibleMs: Int? = nil, hiddenMs: Int? = nil,
        handler: @escaping Handler
    ) -> UUID {
        let token = UUID()
        lock.lock()
        desired[token] = Desired(
            command: command, params: params, visibleMs: visibleMs, hiddenMs: hiddenMs, handler: handler
        )
        lock.unlock()
        enqueue { await self.activate(token) }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock()
        let removed = desired.removeValue(forKey: token)
        if let id = removed?.agentID { byAgentID[id] = nil }
        lock.unlock()
        guard let id = removed?.agentID else { return }
        enqueue { try? await self.client.unsubscribe(id) }
    }

    /// A view that needs measurements reports itself (visible: it is on screen).
    /// While at least one is visible the agent samples at the visible
    /// interval, otherwise at the hidden one.
    public func setVisible(_ visible: Bool, owner: String) {
        lock.lock()
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
        lock.unlock()
        enqueue { await self.syncVisibility() }
    }

    private func activate(_ token: UUID) async {
        guard case .ready = state else { return }
        guard let entry: Desired = lock.withLock({
            guard let entry = desired[token], entry.agentID == nil, !entry.ended else { return nil }
            return entry
        }) else { return }
        do {
            let id = try await client.subscribe(
                entry.command, params: entry.params, visibleMs: entry.visibleMs, hiddenMs: entry.hiddenMs
            )
            let kept = lock.withLock { () -> Bool in
                guard desired[token] != nil else { return false }
                desired[token]?.agentID = id
                byAgentID[id] = token
                for event in early.removeValue(forKey: id) ?? [] { deliver(event, to: entry.handler) }
                return true
            }
            if !kept { try? await client.unsubscribe(id) } // cancelled while the agent answered
        } catch {
            guard let remote = error as? AgentRemoteError else { return } // a dead agent is the state
            lock.withLock { desired[token]?.ended = true }
            deliveryQueue.async {
                entry.handler(AgentEvent(
                    subscriptionID: -1, command: entry.command, sequence: 0, monotonicMs: 0,
                    payload: .error(remote), ended: true
                ))
            }
        }
    }

    private func resynchronize() async {
        for token in lock.withLock({ Array(desired.keys) }) { await activate(token) }
        await syncVisibility()
    }

    private func syncVisibility() async {
        guard case .ready = state else { return }
        let (visible, changed) = lock.withLock {
            (!visibleOwners.isEmpty, !visibleOwners.isEmpty != visibleAtAgent)
        }
        guard changed else { return }
        do {
            try await client.setVisibility(visible)
            lock.withLock { visibleAtAgent = visible }
        } catch {}
    }

    private func route(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        if let token = byAgentID[event.subscriptionID], let entry = desired[token] {
            if event.ended {
                byAgentID[event.subscriptionID] = nil
                desired[token]?.agentID = nil
                desired[token]?.ended = true
            }
            deliver(event, to: entry.handler)
        } else {
            early[event.subscriptionID, default: []].append(event)
        }
    }

    /// Call with the lock held: the queue keeps the order of the calls.
    private func deliver(_ event: AgentEvent, to handler: @escaping Handler) {
        deliveryQueue.async { handler(event) }
    }

    /// Agent requests of the session run one after another, so a visibility
    /// change cannot overtake the subscribe it belongs to.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        lock.unlock()
    }

    /// Returns when every request the session queued so far has been answered.
    func settled() async {
        await lock.withLock { tail }?.value
    }

    // MARK: Actions

    /// Runs `command`. Reversible commands run at once; a risky one returns
    /// `.needsConfirmation` and nothing has happened yet.
    public func perform(_ command: String, params: [String: AgentJSON] = [:]) async -> ActionOutcome {
        do {
            switch try await client.call(command, params: params) {
            case .ok(_, _, let output):
                return .done(output)
            case .confirmationRequired(let name, let planID, let plan):
                return .needsConfirmation(AgentPlan(command: name, planID: planID, plan: plan))
            }
        } catch {
            return Self.failed(error)
        }
    }

    /// Executes a plan the user approved in the app.
    public func confirm(_ plan: AgentPlan) async -> ActionOutcome {
        do {
            let report = try await client.confirm(planID: plan.id)
            guard report["status"]?.stringValue == "confirmed" else {
                let message = report["error"]?["message"]?.stringValue
                    ?? "\(plan.command) was not applied (\(report["status"]?.stringValue ?? "unknown"))."
                return .failed(message: message, exitClass: report["error"]?["data"]?["class"]?.stringValue)
            }
            return .done(report["output"] ?? .null)
        } catch {
            return Self.failed(error)
        }
    }

    /// The one argument a register command takes (its `input_schema`), or `nil`
    /// when it takes none or several (or no agent answered `hello` yet).
    public func argumentName(of command: String) -> String? {
        guard case .object(let properties)? = schemaProperties(of: command), properties.count == 1 else { return nil }
        return properties.keys.first
    }

    /// What to send as that argument to clear a setting: the CLI's `off` when
    /// the argument is text, otherwise `null`.
    public func clearValue(of command: String) -> AgentJSON {
        guard case .object(let properties)? = schemaProperties(of: command),
              properties.count == 1, properties.values.first?["type"]?.stringValue == "string"
        else { return .null }
        return .string("off")
    }

    private func schemaProperties(of command: String) -> AgentJSON? {
        hello?.commands.first { $0.name == command }?.inputSchema["properties"]
    }

    /// A read command, decoded. Throws what `perform` would report as failure.
    public func read<T: Decodable>(_ type: T.Type, _ command: String, params: [String: AgentJSON] = [:]) async throws -> T {
        switch await perform(command, params: params) {
        case .done(let output): return try AgentDecoding.decode(type, from: output)
        case .failed(let message, _): throw AgentFailure.protocolViolation(message)
        case .needsConfirmation: throw AgentFailure.protocolViolation("\(command) needs a confirmation")
        }
    }

    private static func failed(_ error: Error) -> ActionOutcome {
        if let remote = error as? AgentRemoteError {
            return .failed(message: remote.message, exitClass: remote.exitClass)
        }
        return .failed(message: error.localizedDescription, exitClass: nil)
    }
}

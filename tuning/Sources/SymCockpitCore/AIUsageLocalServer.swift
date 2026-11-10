import Foundation
import Network

/// Explicitly constructed/started only: no automatic listener or provider calls.
/// The closure must be a fast, thread-safe in-memory cache read, never a fetch.
/// One request per connection; no bodies, pipelining, keep-alive, or CORS.
/// A same-user local process can read the snapshot; this is not an auth boundary
/// between users on the same Mac. All web-origin reads are refused.
public final class AIUsageLocalServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case alreadyStarted
        case startupTimeout
        case bindFailed(String)
    }

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var timer: DispatchWorkItem?
        var responding = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "com.symaira.cockpit.usage-http")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let requestedPort: UInt16
    private let snapshot: @Sendable () -> [AIUsageService.ProviderResult]
    private var listener: NWListener?
    private let cancellations = DispatchGroup()
    private var clients: [UUID: Client] = [:]
    private var boundPort: UInt16?
    private var startupError: ServerError?

    /// Port zero asks the OS for an ephemeral port (tests); CLI opt-in uses 6737.
    public init(port: UInt16 = 6737, snapshots: @escaping @Sendable () -> [AIUsageService.ProviderResult]) {
        requestedPort = port
        snapshot = snapshots
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Waits at most three seconds for a real bind. Errors are never suppressed.
    /// Call from outside the cache's synchronization queue.
    @discardableResult
    public func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        try queue.sync {
            guard listener == nil else { throw ServerError.alreadyStarted }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort)!)
            parameters.allowLocalEndpointReuse = false
            let pending = try NWListener(using: parameters)
            listener = pending
            startupError = nil
            boundPort = nil
            let cancellations = self.cancellations
            cancellations.enter()
            pending.stateUpdateHandler = { [weak self, weak pending] state in
                // Cancellation is asynchronous, even after cancel() returns.
                if case .cancelled = state { cancellations.leave(); ready.signal() }
                guard let self, let pending, self.listener === pending else { return }
                switch state {
                case .ready:
                    self.boundPort = pending.port?.rawValue
                    ready.signal()
                case .failed(let error):
                    self.startupError = .bindFailed(String(describing: error))
                    self.close()
                    ready.signal()
                default: break
                }
            }
            pending.newConnectionHandler = { [weak self, weak pending] connection in
                guard let self, let pending, self.listener === pending else { connection.cancel(); return }
                self.accept(connection)
            }
            pending.start(queue: queue)
        }
        guard ready.wait(timeout: .now() + 3) == .success else {
            stop()
            throw ServerError.startupTimeout
        }
        return try queue.sync {
            if let error = startupError { throw error }
            guard let port = boundPort else { throw ServerError.bindFailed("listener cancelled") }
            return port
        }
    }

    /// Revokes access on the callback queue and waits up to three seconds total
    /// for queue admission and native cancellation. False means shutdown is still
    /// pending (including on-queue calls); off-queue stop() can observe completion.
    @discardableResult
    public func stop() -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            close()
            return cancellations.wait(timeout: .now()) == .success
        }
        let deadline = DispatchTime.now() + 3
        let closed = DispatchSemaphore(value: 0)
        queue.async { [weak self] in self?.close(); closed.signal() }
        guard closed.wait(timeout: deadline) == .success else { return false }
        return cancellations.wait(timeout: deadline) == .success
    }

    deinit {
        // Do not enqueue a reference to an object that is already deinitializing.
        if DispatchQueue.getSpecific(key: queueKey) == true { close() } else {
            queue.sync { close() }
            _ = cancellations.wait(timeout: .now() + 3)
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        for id in Array(clients.keys) { finish(id) }
    }

    private func accept(_ connection: NWConnection) {
        // Reserve the sixteenth slot for a bounded 503 response. Once all slots
        // are occupied, immediately cancel rather than queue unbounded rejects.
        guard clients.count < 16 else { connection.cancel(); return }
        let busy = clients.count >= 15
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, let client = self.clients[id] else { return }
            if client.responding { self.finish(id) } else {
                self.respond(id, AIUsageLocalAPI.error(408, "request_timeout"))
            }
        }
        client.timer = deadline
        queue.asyncAfter(deadline: .now() + 3, execute: deadline)
        let cancellations = self.cancellations
        cancellations.enter()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { cancellations.leave() }
            switch state {
            case .failed, .cancelled: self?.finish(id)
            default: break
            }
        }
        connection.start(queue: queue)
        if busy { respond(id, AIUsageLocalAPI.error(503, "server_busy")) } else { receive(id) }
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id], !client.responding else { return }
        client.connection.receive(
            minimumIncompleteLength: 1, maximumLength: 8193 - client.buffer.count
        ) { [weak self] data, _, complete, error in
            guard let self, let client = self.clients[id], !client.responding else { return }
            if let data { client.buffer.append(data) }
            if client.buffer.count > 8192 {
                self.respond(id, AIUsageLocalAPI.error(431, "headers_too_large"))
            } else if let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == client.buffer.endIndex else {
                    self.respond(id, AIUsageLocalAPI.error(413, "body_not_allowed")); return
                }
                self.respond(id, AIUsageLocalAPI.route(header: client.buffer, port: self.boundPort ?? 0,
                                                       snapshots: self.snapshot))
            } else if complete || error != nil {
                self.respond(id, AIUsageLocalAPI.error(400, "bad_request"))
            } else { self.receive(id) }
        }
    }

    private func respond(_ id: UUID, _ response: AIUsageLocalAPI.Response) {
        guard let client = clients[id], !client.responding else { return }
        client.responding = true
        client.buffer = Data()
        client.timer?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.finish(id) }
        client.timer = deadline
        queue.asyncAfter(deadline: .now() + 1, execute: deadline)
        client.connection.send(content: response.httpData(), completion: .contentProcessed { [weak self] _ in
            self?.finish(id)
        })
    }

    private func finish(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.cancel()
        client.connection.cancel()
    }
}

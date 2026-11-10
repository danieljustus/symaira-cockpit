import Foundation
import Observation
import SymCockpitCore

/// Opt-in GUI listener. Only already displayed, enabled-provider rows cross
/// into the server's in-memory store; HTTP cannot request credential work.
@MainActor
@Observable
final class AIUsageAPIHost {
    private(set) var status = "Local API is off"
    private let snapshots = AIUsageLocalSnapshots()
    private var server: AIUsageLocalServer?
    private var requestedEnabled = false
    private let port: UInt16

    init(port: UInt16 = 6737) { self.port = port }

    func update(enabled: Bool, rows: [AIUsageService.ProviderResult]) {
        snapshots.replace(enabled ? rows : [])
        guard enabled != requestedEnabled else { return }
        requestedEnabled = enabled
        guard enabled else { stop(); return }
        let store = snapshots
        let instance = AIUsageLocalServer(port: port, snapshots: { store.read() })
        server = instance
        status = "Starting local API…"
        Task { [weak self] in
            let result = await Task.detached { try instance.start() }.result
            guard let self, self.server === instance, self.requestedEnabled else {
                Self.stopOffMain(instance)
                return
            }
            switch result {
            case .success(let port): self.status = "Local API: 127.0.0.1:\(port)"
            case .failure:
                Self.stopOffMain(instance)
                self.server = nil
                self.status = "Could not start local API on port \(self.port). Disable it, free the port, then retry."
            }
        }
    }

    func stop() {
        requestedEnabled = false
        snapshots.replace([])
        if let old = server { Self.stopOffMain(old) }
        server = nil
        status = "Local API is off"
    }

    /// `AIUsageLocalServer.stop()` can wait up to three seconds for its queue,
    /// so it never runs on the main actor. Stopping is final and idempotent:
    /// an instance whose start is still pending cannot listen afterwards.
    private nonisolated static func stopOffMain(_ server: AIUsageLocalServer) {
        server.invalidate()  // Synchronous and non-blocking: a pending start can no longer bind.
        Task.detached { server.stop() }
    }

    /// Best effort: the stop and the final release both happen off the main actor.
    isolated deinit { if let server { Self.stopOffMain(server) } }
}

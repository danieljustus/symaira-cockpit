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
                instance.stop()
                return
            }
            switch result {
            case .success(let port): self.status = "Local API: 127.0.0.1:\(port)"
            case .failure:
                instance.stop()
                self.server = nil
                self.status = "Could not start local API on port 6737. Disable it, free the port, then retry."
            }
        }
    }

    func stop() {
        requestedEnabled = false
        snapshots.replace([])
        server?.stop()
        server = nil
        status = "Local API is off"
    }

    isolated deinit { server?.stop() }
}

import Foundation
import SwiftUI
import SymScopeCore

/// Live inventory behind the Scope section: listening ports, their conflicts,
/// containers, and the MCP servers configured on this machine.
///
/// It calls the very same `SymScopeCore` services `symcockpit scope` does, so
/// the window and the CLI cannot disagree. Polling only runs while the cockpit
/// window is on screen — a closed window costs nothing.
@MainActor
final class ScopeViewModel: ObservableObject {
    @Published private(set) var ports: [SymScopeCore.Port] = []
    @Published private(set) var conflicts: [Conflict] = []
    @Published private(set) var containers: [Container] = []
    @Published private(set) var mcpServers: [MCPServer] = []
    @Published private(set) var daemons: [Daemon] = []
    @Published private(set) var daemonNotes: [String] = []
    @Published private(set) var mcpNotes: [String] = []
    @Published private(set) var containerNotes: [String] = []
    @Published private(set) var health: [String: MCPHealthResult] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingHealth = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var suggestedPorts: [Int] = []

    /// Ports and containers churn on a developer machine, but not by the
    /// second; 15s keeps the list honest without turning `lsof` into a tax.
    private let refreshInterval: Duration = .seconds(15)
    private var pollTask: Task<Void, Never>?

    /// Health keys off name+client, the pair that identifies a server across
    /// the discovered client configs.
    static func healthKey(_ server: MCPServer) -> String {
        "\(server.client)/\(server.name)"
    }

    func setVisible(_ visible: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard visible else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func refreshNow(includeApple: Bool = false) {
        Task { await refresh(includeApple: includeApple) }
    }

    func refresh(includeApple: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // All four of these shell out to external binaries — discovery runs
        // `symbrain harness list` through the synchronous BoundedProcessRunner,
        // so it must leave the main actor like the other three or it blocks the
        // window for that call's timeout budget on every refresh.
        //
        // One port inventory, shared. This view and `DaemonService` both want
        // it — the daemon rows are annotated with the ports their PID holds —
        // and letting the service collect its own ran `lsof` a second time
        // every 15 seconds, for a list this refresh then overwrote anyway.
        let portsTask = Task.detached { (try? await PortService.listListening()) ?? [] }
        async let discoveryResult = Task.detached { MCPDiscovery.discover() }.value
        async let containersResult = ContainerService.list()
        async let daemonsResult = DaemonService(
            portProvider: { await portsTask.value }
        ).list(all: includeApple)

        let (discovered, notes) = await discoveryResult
        let listening = await portsTask.value
        let (containerList, cNotes) = await containersResult
        let (daemonList, dNotes) = await daemonsResult

        ports = listening.sorted { $0.port < $1.port }
        // Already annotated by `DaemonService.list`, from this very inventory.
        daemons = daemonList
        conflicts = ConflictDetector.detect(listening, daemons: daemons)
        containers = containerList
        containerNotes = cNotes
        mcpServers = discovered.sorted { ($0.client, $0.name) < ($1.client, $1.name) }
        mcpNotes = notes
        daemonNotes = dNotes
        errorMessage = nil
        lastUpdated = Date()
    }

    /// Ask scope for free ports to hand a new service — the GUI equivalent of
    /// `symcockpit scope ports suggest`.
    func suggestPorts(count: Int = 3) {
        Task {
            let free = (try? await PortService.suggestFree(count: count)) ?? []
            suggestedPorts = free
        }
    }

    /// Ask symbrain for the health of every registered MCP server. Probing is
    /// delegated to symbrain so this view cannot diverge from the harness CLI.
    func checkHealth() {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        let service = SymBrainHarnessService()
        Task { @MainActor in
            let results = await Task.detached { service.health() ?? [] }.value
            health = Dictionary(
                results.map { ("\($0.client)/\($0.name)", $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            isCheckingHealth = false
        }
    }

    var conflictedPorts: Set<Int> {
        Set(conflicts.map(\.port))
    }
}

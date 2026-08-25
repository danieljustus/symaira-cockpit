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

        // Discovery is filesystem-only and synchronous; ports and containers
        // shell out, so they run concurrently rather than back to back.
        async let portsResult: [SymScopeCore.Port] = (try? await PortService.listListening()) ?? []
        async let containersResult = ContainerService.list()
        async let daemonsResult = DaemonService.list(all: includeApple)

        let (discovered, notes) = MCPDiscovery.discover()
        let listening = await portsResult
        let (containerList, cNotes) = await containersResult
        let (daemonList, dNotes) = await daemonsResult

        ports = listening.sorted { $0.port < $1.port }
        daemons = DaemonService.annotatePorts(daemonList, ports: listening)
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

    /// Probe every discovered MCP server. This actually launches stdio servers,
    /// so it stays an explicit user action rather than part of the poll.
    func checkHealth() {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        let servers = mcpServers
        Task {
            let results = await MCPHealthService.checkAll(servers)
            // Every result carries the name/client pair it was probed for, so
            // the map keys off the result itself rather than off input order.
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

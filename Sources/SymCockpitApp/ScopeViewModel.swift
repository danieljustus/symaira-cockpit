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
    private var daemonCache = DaemonRefreshCache()
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
        Task { await refresh(includeApple: includeApple, forceDaemonRefresh: true) }
    }

    func refresh(includeApple: Bool = false, forceDaemonRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Port, container and MCP discovery remain on the 15-second cadence.
        // Daemon discovery is the expensive launchd/Homebrew inventory, so it
        // uses a longer cache cadence unless this is an explicit refresh.
        let portsTask = Task.detached { (try? await PortService.listListening()) ?? [] }
        async let discoveryResult = Task.detached { MCPDiscovery.discover() }.value
        async let containersResult = ContainerService.list()

        let shouldRefreshDaemons = daemonCache.beginRefresh(
            at: Date(),
            force: forceDaemonRefresh
        )
        let daemonTask: Task<([Daemon], [String]), Never>?
        if shouldRefreshDaemons {
            daemonTask = Task.detached {
                await DaemonService(
                    portProvider: { await portsTask.value }
                ).list(all: includeApple)
            }
        } else {
            daemonTask = nil
        }

        let (discovered, notes) = await discoveryResult
        let listening = await portsTask.value
        let (containerList, cNotes) = await containersResult
        if let daemonTask {
            let (daemonList, dNotes) = await daemonTask.value
            daemonCache.update(daemons: daemonList, notes: dNotes)
        }
        daemonCache.annotatePorts(listening)

        ports = listening.sorted { $0.port < $1.port }
        daemons = daemonCache.daemons
        conflicts = ConflictDetector.detect(listening, daemons: daemons)
        containers = containerList
        containerNotes = cNotes
        mcpServers = discovered.sorted { ($0.client, $0.name) < ($1.client, $1.name) }
        mcpNotes = notes
        daemonNotes = daemonCache.notes
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

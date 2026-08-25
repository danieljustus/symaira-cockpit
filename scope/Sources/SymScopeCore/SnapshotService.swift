import Foundation

/// Aggregate snapshot: ports + MCP servers + containers + background services.
/// Mirrors the Go original's scan.Build (concurrent collection, notes for
/// non-fatal degradations).
public struct SnapshotService: Sendable {
    public static func build() async -> Snapshot {
        async let portsTask: (ports: [Port], notes: [String]) = {
            do {
                return (try await PortService.listListening(), [])
            } catch {
                return ([], ["ports: \(error.localizedDescription)"])
            }
        }()

        async let daemonsTask = DaemonService.list()
        let (servers, serverNotes) = MCPDiscovery.discover()

        async let containersTask: (containers: [Container], notes: [String]) = {
            let (containers, notes) = await ContainerService.list()
            return (containers, notes)
        }()

        let portsResult = await portsTask
        let daemonsResult = await daemonsTask
        let containersResult = await containersTask

        let daemons = DaemonService.annotatePorts(daemonsResult.0, ports: portsResult.ports)
        let notes = portsResult.notes + serverNotes + containersResult.notes + daemonsResult.1

        // ISO8601 generated_at, matching the Go original's layout.
        let formatter = ISO8601DateFormatter()
        let generatedAt = formatter.string(from: Date())

        return Snapshot(
            generatedAt: generatedAt,
            ports: portsResult.ports,
            mcpServers: servers,
            containers: containersResult.containers,
            daemons: daemons,
            notes: notes
        )
    }
}

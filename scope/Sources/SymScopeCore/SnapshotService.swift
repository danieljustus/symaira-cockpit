import Foundation

/// Aggregate snapshot: ports + MCP servers + containers in one structure.
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

        let (servers, serverNotes) = MCPDiscovery.discover()

        async let containersTask: (containers: [Container], notes: [String]) = {
            let (containers, notes) = await ContainerService.list()
            return (containers, notes)
        }()

        let portsResult = await portsTask
        let containersResult = await containersTask

        var notes = portsResult.notes + serverNotes + containersResult.notes

        // ISO8601 generated_at, matching the Go original's layout.
        let formatter = ISO8601DateFormatter()
        let generatedAt = formatter.string(from: Date())

        return Snapshot(
            generatedAt: generatedAt,
            ports: portsResult.ports,
            mcpServers: servers,
            containers: containersResult.containers,
            notes: notes
        )
    }
}

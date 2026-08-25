import SwiftUI
import SymairaTheme
import SymScopeCore

/// The Scope section: what is listening, what is running in a container, and
/// which MCP servers this machine is configured to launch.
///
/// Every card filters off one search box at the top. On a working machine this
/// list runs to dozens of rows across three categories, and the question is
/// almost always about one specific thing — a port number, a container name —
/// so a single filter beats three separate ones.
@MainActor
struct ScopeView: View {
    @ObservedObject var model: ScopeViewModel

    @State private var query = ""
    @State private var showAllDaemons = false

    var body: some View {
        CockpitSectionScroll(
            title: "Scope",
            command: CockpitSection.scope.command,
            status: status
        ) {
            CockpitSearchField(placeholder: "Filter ports, containers, services and servers", text: $query)

            conflictsCard
            portsCard
            containersCard
            daemonsCard
            mcpCard
        }
        .onAppear { model.refreshNow(includeApple: showAllDaemons) }
        .onChange(of: showAllDaemons) { _, includeApple in
            model.refreshNow(includeApple: includeApple)
        }
    }

    private var status: String? {
        guard let updated = model.lastUpdated else { return model.isLoading ? "scanning…" : nil }
        return "updated \(updated.formatted(date: .omitted, time: .standard))"
    }

    private func matches(_ fields: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Conflicts

    /// Conflicts come first and never fold: a contested port is the one thing
    /// in this section that is actually wrong, and it is worth nothing at the
    /// bottom of a long list.
    @ViewBuilder
    private var conflictsCard: some View {
        if !model.conflicts.isEmpty {
            CockpitCard(
                title: "Conflicts",
                subtitle: "More than one holder on the same port",
                count: model.conflicts.count
            ) {
                CockpitList(items: model.conflicts) { conflict, _ in
                    CockpitRow {
                        HStack(spacing: SymairaSpacing.medium) {
                            portNumber(conflict.port, tint: SymairaTheme.warning)
                            CockpitRowLabel(
                                title: conflict.holders.joined(separator: ", "),
                                detail: conflict.kind
                            )
                        }
                    } trailing: {
                        CockpitBadge(text: "conflict", tint: SymairaTheme.warning)
                    }
                }
            }
        }
    }

    // MARK: - Ports

    private var filteredPorts: [SymScopeCore.Port] {
        model.ports.filter { matches(String($0.port), $0.process, $0.address, $0.protocol_) }
    }

    private var portsCard: some View {
        CockpitDisclosureCard(
            title: "Listening ports",
            subtitle: subtitle(shown: filteredPorts.count, total: model.ports.count),
            count: model.ports.count,
            trailing: AnyView(
                HStack(spacing: SymairaSpacing.small) {
                    Button("Suggest free") { model.suggestPorts() }
                        .buttonStyle(.borderless)
                        .font(SymairaTypography.caption)
                        .help("Three unused ports in the ephemeral range")
                    CockpitRefreshButton(isLoading: model.isLoading) { model.refreshNow() }
                }
            ),
            storageKey: "scope.ports"
        ) {
            if !model.suggestedPorts.isEmpty {
                HStack(spacing: SymairaSpacing.small) {
                    Text("Free")
                        .font(SymairaTypography.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                    ForEach(model.suggestedPorts, id: \.self) { port in
                        CockpitBadge(text: String(port), tint: SymairaTheme.positive)
                            .textSelection(.enabled)
                    }
                }
            }

            if filteredPorts.isEmpty {
                emptyRow(
                    total: model.ports.count,
                    empty: "Nothing is listening.",
                    symbol: "antenna.radiowaves.left.and.right.slash"
                )
            } else {
                let conflicted = model.conflictedPorts
                CockpitList(items: filteredPorts) { port, _ in
                    CockpitRow {
                        HStack(spacing: SymairaSpacing.medium) {
                            portNumber(
                                port.port,
                                tint: conflicted.contains(port.port) ? SymairaTheme.warning : SymairaTheme.textPrimary
                            )
                            CockpitRowLabel(
                                title: port.process,
                                detail: "pid \(String(port.pid)) · \(port.protocol_) · \(port.address)",
                                monospacedDetail: true
                            )
                        }
                    } trailing: {
                        if conflicted.contains(port.port) {
                            CockpitBadge(text: "conflict", tint: SymairaTheme.warning)
                        }
                    }
                }
            }
        }
    }

    /// Port numbers get a fixed column so the process names below them line up
    /// into a readable second column instead of stair-stepping.
    private func portNumber(_ port: Int, tint: Color) -> some View {
        Text(String(port))
            .font(SymairaTypography.mono)
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 62, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Containers

    private var filteredContainers: [Container] {
        model.containers.filter { matches($0.name, $0.image, $0.id) }
    }

    private var containersCard: some View {
        CockpitDisclosureCard(
            title: "Containers",
            subtitle: subtitle(shown: filteredContainers.count, total: model.containers.count),
            count: model.containers.count,
            storageKey: "scope.containers"
        ) {
            if filteredContainers.isEmpty {
                emptyRow(
                    total: model.containers.count,
                    empty: model.containerNotes.first ?? "No running containers.",
                    symbol: "shippingbox"
                )
            } else {
                CockpitList(items: filteredContainers) { container, _ in
                    CockpitRow {
                        CockpitRowLabel(title: container.name, detail: container.image)
                    } trailing: {
                        if !container.ports.isEmpty {
                            Text(container.ports.map(String.init).joined(separator: ", "))
                                .font(SymairaTypography.monoSmall)
                                .foregroundStyle(SymairaTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Background services

    private var filteredDaemons: [Daemon] {
        model.daemons.filter { daemon in
            matches(
                daemon.label,
                daemon.state,
                daemon.domain,
                daemon.origin,
                daemon.pid.map(String.init) ?? "",
                daemon.ports.map(String.init).joined(separator: " "),
                daemon.notes.joined(separator: " ")
            )
        }
    }

    private var daemonsCard: some View {
        CockpitDisclosureCard(
            title: "Background services",
            subtitle: subtitle(shown: filteredDaemons.count, total: model.daemons.count),
            count: model.daemons.count,
            trailing: AnyView(
                Toggle("Apple", isOn: $showAllDaemons)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Include com.apple.* launchd services")
            ),
            storageKey: "scope.daemons"
        ) {
            if filteredDaemons.isEmpty {
                emptyRow(
                    total: model.daemons.count,
                    empty: "No background services found.",
                    symbol: "gearshape.2"
                )
            } else {
                CockpitList(items: filteredDaemons) { daemon, _ in
                    CockpitRow {
                        CockpitRowLabel(
                            title: daemon.label,
                            detail: "\(daemon.state) · \(daemon.domain) · \(daemon.origin)"
                        )
                    } trailing: {
                        HStack(spacing: SymairaSpacing.small) {
                            if !daemon.ports.isEmpty {
                                Text(daemon.ports.map(String.init).joined(separator: ", "))
                                    .font(SymairaTypography.monoSmall)
                                    .foregroundStyle(SymairaTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .help("Ports held by this PID")
                            }
                            if let status = daemon.lastExitStatus, status != 0 {
                                CockpitBadge(text: "exit \(status)", tint: SymairaTheme.critical)
                            }
                            if let pid = daemon.pid {
                                Text("pid \(pid)")
                                    .font(SymairaTypography.monoSmall)
                                    .foregroundStyle(SymairaTheme.textMuted)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            ForEach(model.daemonNotes, id: \.self) { note in
                Text(note)
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - MCP

    private var filteredServers: [MCPServer] {
        model.mcpServers.filter { matches($0.name, $0.client, $0.transport, $0.command ?? "", $0.url ?? "") }
    }

    private var mcpCard: some View {
        CockpitDisclosureCard(
            title: "MCP servers",
            subtitle: subtitle(shown: filteredServers.count, total: model.mcpServers.count),
            count: model.mcpServers.count,
            trailing: AnyView(
                Button {
                    model.checkHealth()
                } label: {
                    if model.isCheckingHealth {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check health")
                    }
                }
                .buttonStyle(.borderless)
                .font(SymairaTypography.caption)
                .disabled(model.mcpServers.isEmpty || model.isCheckingHealth)
                .help("Probe every configured server — this launches stdio servers")
            ),
            storageKey: "scope.mcp"
        ) {
            if filteredServers.isEmpty {
                emptyRow(
                    total: model.mcpServers.count,
                    empty: "No MCP servers found in any client config.",
                    symbol: "point.3.connected.trianglepath.dotted"
                )
            } else {
                CockpitList(items: filteredServers) { server, _ in
                    mcpRow(server)
                }
            }

            ForEach(model.mcpNotes, id: \.self) { note in
                Text(note)
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mcpRow(_ server: MCPServer) -> some View {
        let result = model.health[ScopeViewModel.healthKey(server)]
        return CockpitRow {
            CockpitRowLabel(
                title: server.name,
                detail: "\(server.client) · \(server.transport)"
            )
        } trailing: {
            HStack(spacing: SymairaSpacing.small) {
                if !server.credentialWarnings.isEmpty {
                    CockpitBadge(text: "plaintext secret", tint: SymairaTheme.warning)
                        .help(server.credentialWarnings.joined(separator: "\n"))
                }
                if let result {
                    CockpitBadge(
                        text: result.status == "healthy"
                            ? "\(result.latencyMs) ms"
                            : result.status,
                        tint: tint(for: result.status)
                    )
                    .help(result.error ?? "\(result.status) · \(result.latencyMs) ms")
                }
            }
        }
    }

    // MARK: - Shared bits

    /// Only says "x of y" while a filter is actually hiding something.
    private func subtitle(shown: Int, total: Int) -> String? {
        guard !query.isEmpty, shown != total else { return nil }
        return "\(shown) of \(total) match “\(query)”"
    }

    /// Distinguishes "the filter hid everything" from "there is nothing here",
    /// and both from "still loading".
    private func emptyRow(total: Int, empty: String, symbol: String) -> some View {
        if total > 0 {
            return CockpitEmptyRow(text: "No match for “\(query)”.", symbol: "line.3.horizontal.decrease")
        }
        if model.lastUpdated == nil, model.isLoading {
            return CockpitEmptyRow(text: "Scanning…", isLoading: true)
        }
        return CockpitEmptyRow(text: empty, symbol: symbol)
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "healthy": return SymairaTheme.positive
        case "unhealthy": return SymairaTheme.critical
        default: return SymairaTheme.textMuted
        }
    }
}

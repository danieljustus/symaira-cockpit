import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Where the space of one folder goes: a tree of sizes, as deep as asked.
@MainActor
struct StorageSpaceCard: View {
    @Bindable var model: SpaceModel
    let gate: AgentWorkGate
    let isPrimary: Bool

    var body: some View {
        PageCard(
            title: "Space Analysis", icon: .folder,
            detail: "Choose a folder to see which items take the space. Sizes are what the disk really allocates.",
            identifier: "storage-space"
        ) {
            controls
            SectionStateView(
                state: model.state, loading: "Measuring “\(StorageFormat.shortPath(model.folder ?? ""))”… This can take a while for a large folder.",
                retry: gate.isBusy ? nil : { Task { await model.analyze() } },
                idle: { MutedNote("No folder chosen yet.") },
                loaded: { report in tree(report) }
            )
        }
    }

    private var controls: some View {
        HStack(spacing: SymairaSpacing.small) {
            Button("Choose Folder…") {
                if let path = FilePanels.chooseFolder(message: "Choose the folder to analyse.", prompt: "Analyse") {
                    Task { await model.analyze(path) }
                }
            }
            .symairaButtonStyle(isPrimary ? .primary : .secondary)
            .disabled(gate.isBusy)
            SymairaFilterMenu(
                "Tree depth", selection: $model.depth,
                options: SpaceModel.depths.map { ($0, $0 == 1 ? "1 level" : "\($0) levels") }
            )
            .disabled(gate.isBusy)
            .onChange(of: model.depth) { _, _ in
                if model.folder != nil { Task { await model.analyze() } }
            }
            if let folder = model.folder {
                Text(StorageFormat.shortPath(folder))
                    .symairaText(.monoSmall)
                    .foregroundStyle(SymairaTokens.ink2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(folder)
            }
            Spacer(minLength: 0)
        }
    }

    private func tree(_ report: SpaceReport) -> some View {
        let total = max(report.root.allocatedBytes, 1)
        return VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            HStack(spacing: SymairaSpacing.xLarge) {
                SymairaStatTile(value: StorageFormat.size(report.root.allocatedBytes), label: "In This Folder", showsCard: false)
                SymairaStatTile(
                    value: StorageFormat.count(report.entriesVisited), label: "Items Looked At",
                    detail: report.errorCount > 0 ? "\(report.errorCount) could not be read" : nil, showsCard: false
                )
            }
            if report.truncated {
                SymairaNotice(message: "The folder is too large to read completely; the tree shows what was measured before the agent stopped.", tone: .warning)
            }
            if let children = report.root.children {
                OutlineGroup(children, children: \.children) { node in
                    SpaceRow(node: node, total: total)
                }
            } else {
                MutedNote(report.errorCount > 0 ? "No readable entries at this depth." : "No entries at this depth.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size tree of \(report.path)")
    }
}

private struct SpaceRow: View {
    let node: SpaceNode
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SymairaSpacing.small) {
                SymairaIconView(node.isDirectory ? .folder : .document, size: 14)
                    .foregroundStyle(SymairaTokens.ink3)
                    .accessibilityHidden(true)
                Text(node.name)
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: SymairaSpacing.small)
                Text(StorageFormat.size(node.allocatedBytes))
                    .symairaText(.monoSmall, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .monospacedDigit()
            }
            ProgressView(value: min(Double(node.allocatedBytes) / Double(total), 1))
                .progressViewStyle(CockpitProgressStyle(height: 3))
                .accessibilityLabel("Share of the folder")
                .accessibilityValue(String(format: "%.0f%%", Double(node.allocatedBytes) / Double(total) * 100))
        }
        .help(node.name)
    }
}

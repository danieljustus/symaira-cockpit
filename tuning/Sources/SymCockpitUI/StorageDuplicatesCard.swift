import SwiftUI
import SymCockpitCore
import SymairaTheme

@MainActor
struct StorageDuplicatesCard: View {
    @Bindable var model: DuplicatesModel
    let gate: AgentWorkGate

    var body: some View {
        PageCard(title: "Duplicate Files", icon: .copy, identifier: "storage-duplicates") {
            controls
            if let confirmation = model.confirmation {
                PlanConfirmationView(
                    model: confirmation, summary: "Moves the selected copies to the Trash and keeps a verified copy in each group.",
                    confirmTitle: "Move to Trash", onClose: { model.closeConfirmation() }
                )
            } else if model.planning {
                SymairaLoadingState("Checking the selected files and recording the removal plan…")
            } else {
                SectionStateView(
                    state: model.state, loading: "Searching for identical files…",
                    retry: gate.isBusy ? nil : { Task { await model.search() } },
                    idle: { MutedNote("Choose a folder to search for identical files.") },
                    loaded: { scan in results(scan) }
                )
            }
        }
    }

    private var controls: some View {
        HStack(spacing: SymairaSpacing.small) {
            Button("Choose Folder…") {
                if let path = FilePanels.chooseFolder(message: "Choose the folder to search for duplicates.", prompt: "Search") {
                    Task { await model.search(path) }
                }
            }
            .symairaButtonStyle(.secondary)
            SymairaFilterMenu(
                "Minimum file size", selection: $model.minimumSize,
                options: DuplicatesModel.minimumSizes.map { ($0.bytes, $0.label) }
            )
            if model.folder != nil {
                Button("Search Again") { Task { await model.search() } }
                    .symairaButtonStyle(.secondary)
            }
        }
        .disabled(gate.isBusy || model.confirmation != nil)
    }

    private func results(_ scan: DuplicateScan) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            MutedNote("\(scan.root) · \(StorageFormat.count(scan.filesSeen)) files · Minimum \(StorageFormat.size(scan.minSize))")
            if scan.unreadable > 0 || scan.hardlinksSkipped > 0 {
                SymairaNotice(
                    message: "\(scan.unreadable) unreadable files · \(scan.hardlinksSkipped) hard links skipped",
                    tone: .warning
                )
            }
            if scan.groups.isEmpty {
                MutedNote("No identical files found. Try another folder or a smaller minimum size.")
            } else {
                MutedNote("\(scan.groupCount) groups · Up to \(StorageFormat.size(scan.reclaimableBytes)) reclaimable. Keep at least one copy per group.")
                selection
                LazyVStack(alignment: .leading, spacing: SymairaSpacing.small) {
                    ForEach(scan.groups) { group in groupRow(group) }
                }
            }
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            HStack(spacing: SymairaSpacing.small) {
                Button("Mark All but One") { model.markAllButFirst() }
                    .symairaButtonStyle(.secondary)
                Button("Clear Selection") { model.clearSelection() }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.selectedCount == 0)
            }
            HStack(spacing: SymairaSpacing.small) {
                Button("Review Removal Plan…") { Task { await model.requestRemoval() } }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.selectedCount == 0)
                MutedNote("\(model.selectedCount) selected · \(StorageFormat.size(model.selectedBytes))")
            }
            if let failure = model.failure {
                SymairaNotice(message: failure, tone: .warning)
            }
        }
        .disabled(gate.isBusy)
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        DisclosureGroup("\(group.files.count) copies · \(StorageFormat.size(group.size)) each") {
            VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                ForEach(group.files, id: \.self) { path in
                    let canMark = model.canMark(path, in: group)
                    Toggle(isOn: Binding(get: { model.isSelected(path) }, set: { _ in model.toggle(path, in: group) })) {
                        Text(StorageFormat.shortPath(path) + (canMark ? "" : " · Keeping this copy"))
                            .symairaText(.body)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!canMark || gate.isBusy)
                    .help(path)
                    .accessibilityLabel(canMark ? "Mark \(path) for removal" : "Keeping \(path)")
                }
            }
        }
        .symairaText(.body)
    }
}

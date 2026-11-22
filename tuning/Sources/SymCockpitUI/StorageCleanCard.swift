import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Cleanup by catalog: choose the categories, scan, see what would go, then confirm the plan.
@MainActor
struct StorageCleanCard: View {
    let model: CleanModel
    let gate: AgentWorkGate

    var body: some View {
        PageCard(
            title: "Clean Up", icon: .remove,
            detail: "Caches, logs and build products that apps and Xcode rebuild. Scanning changes nothing; you confirm before anything moves.",
            identifier: "storage-clean"
        ) {
            if model.categoryIDs.isEmpty {
                SymairaNotice(message: "This agent does not offer cleanup categories.", tone: .warning)
            } else {
                categories
            }
            HStack(spacing: SymairaSpacing.small) {
                Button("Scan") { Task { await model.scanSelected() } }
                    .symairaButtonStyle(.secondary)
                    .disabled(gate.isBusy || model.selected.isEmpty || model.confirmation != nil)
                    .help(model.selected.isEmpty ? "Choose at least one category." : "Look for what can be removed")
                if model.selected.isEmpty && !model.categoryIDs.isEmpty {
                    MutedNote("Choose at least one category.")
                }
            }
            if let confirmation = model.confirmation {
                PlanConfirmationView(
                    model: confirmation, summary: summary(model.scan.value),
                    confirmTitle: model.scan.value?.hasPermanentRemoval == true ? "Delete Permanently" : "Move to Trash",
                    onClose: { model.closeConfirmation() }
                )
                .accessibilityIdentifier("clean-plan-confirmation")
            } else {
                SectionStateView(
                    state: model.scan, loading: "Scanning the chosen categories…",
                    retry: gate.isBusy ? nil : { Task { await model.scanSelected() } },
                    idle: { MutedNote("Nothing scanned yet.") },
                    loaded: { scan in result(scan) }
                )
            }
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            ForEach(model.categoryIDs, id: \.self) { id in
                let title = model.scan.value?.categories.first { $0.id == id }?.title ?? CleanModel.title(of: id)
                Toggle(isOn: Binding(get: { model.isSelected(id) }, set: { model.setSelected(id, $0) })) {
                    Text(title)
                        .symairaText(.body, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink)
                }
                .toggleStyle(.checkbox)
                .disabled(gate.isBusy || model.confirmation != nil)
                .accessibilityLabel("Include \(title)")
            }
        }
    }

    private func result(_ scan: CleanScan) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            ForEach(scan.categories) { category in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SymairaSpacing.small) {
                        Text(category.title)
                            .symairaText(.body, respectsForeground: false)
                            .foregroundStyle(SymairaTokens.ink)
                        if category.permanent {
                            SymairaBadge("Permanent", tone: .warning, icon: .warning)
                        }
                        Spacer(minLength: SymairaSpacing.small)
                        Text("\(category.items) items · \(StorageFormat.size(category.bytes))")
                            .symairaText(.caption, respectsForeground: false)
                            .foregroundStyle(SymairaTokens.ink2)
                            .monospacedDigit()
                    }
                    MutedNote(category.reason)
                }
                .accessibilityElement(children: .combine)
            }
            if scan.itemCount == 0 {
                SymairaNotice(message: "Nothing to clean in the chosen categories.", tone: .positive)
            } else {
                Text("\(StorageFormat.count(scan.itemCount)) items, \(StorageFormat.size(scan.totalBytes)) in total")
                    .symairaText(.body, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .monospacedDigit()
                if scan.skipped > 0 {
                    MutedNote("\(scan.skipped) entries were excluded by the agent.")
                }
                Button("Review Plan…") { model.review() }
                    .symairaButtonStyle(.secondary)
                    .disabled(gate.isBusy)
            }
        }
    }

    private func summary(_ scan: CleanScan?) -> String? {
        guard let scan else { return nil }
        let what = "\(StorageFormat.count(scan.itemCount)) items, \(StorageFormat.size(scan.totalBytes))"
        return scan.hasPermanentRemoval
            ? "Moves \(what) to the Trash; categories marked Permanent are removed for good."
            : "Moves \(what) to the Trash. You can put them back from there."
    }
}

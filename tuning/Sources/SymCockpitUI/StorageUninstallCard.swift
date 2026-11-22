import SwiftUI
import SymCockpitCore
import SymairaTheme

@MainActor
struct StorageUninstallCard: View {
    let model: UninstallModel
    let gate: AgentWorkGate

    var body: some View {
        PageCard(title: "Uninstall an App", icon: .remove, identifier: "storage-uninstall") {
            Button("Choose App…") {
                if let path = FilePanels.chooseApp() {
                    Task { await model.plan(appPath: path) }
                }
            }
            .symairaButtonStyle(.secondary)
            .disabled(gate.isBusy || model.confirmation != nil)
            if let confirmation = model.confirmation {
                PlanConfirmationView(
                    model: confirmation, summary: "Moves the approved app and related items to the Trash.",
                    confirmTitle: "Move to Trash", onClose: { model.closeConfirmation() }
                )
            } else {
                SectionStateView(
                    state: model.state, loading: "Checking the app and its leftovers…",
                    retry: retry, idle: { MutedNote("Choose an app to see its related files and exclusions.") },
                    loaded: { plan in details(plan) }
                )
            }
        }
    }

    private var retry: (() -> Void)? {
        guard let path = model.appPath, !gate.isBusy else { return nil }
        return { Task { await model.plan(appPath: path) } }
    }

    private func details(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text(plan.appName)
                .symairaText(.subheading)
            MutedNote("\(plan.bundleID) · \(plan.appPath)")
            if plan.items.isEmpty {
                MutedNote("The agent found no items it can move to the Trash.")
            } else {
                DisclosureGroup("\(plan.items.count) items · \(StorageFormat.size(plan.totalBytes))") {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                            Text(StorageFormat.shortPath(item.path))
                                .symairaText(.body)
                                .textSelection(.enabled)
                            MutedNote("\(item.category.replacingOccurrences(of: "_", with: " ").capitalized) · \(StorageFormat.size(item.bytes))")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .symairaText(.body)
                Button("Review Uninstall Plan…") { model.review() }
                    .symairaButtonStyle(.secondary)
                    .disabled(gate.isBusy)
            }
            if !plan.excluded.isEmpty {
                DisclosureGroup("\(plan.excluded.count) excluded items") {
                    ForEach(plan.excluded) { item in
                        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                            Text(StorageFormat.shortPath(item.path))
                                .symairaText(.body)
                                .textSelection(.enabled)
                            MutedNote(item.reason)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .symairaText(.body)
            }
        }
    }
}

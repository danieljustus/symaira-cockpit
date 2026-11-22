import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Storage in the workspace sidebar.
// 2. Job: inspect mounted volumes and find what uses their space.
// 3. Data: shared agent metrics, SMART and history on entry, scans and plans on demand.
// 4. States: per-card loading, empty results, retryable errors and unavailable operations;
//    the workspace shows the agent diagnosis when disconnected.
// 5. Density: dashboard cards in a single scroll column.
// 6. Platform: macOS workspace, with no preference keys.

@MainActor
struct StoragePage: View {
    let model: StoragePageModel
    let metrics: TuneViewModel
    let isWindowVisible: Bool

    private var gate: AgentWorkGate { model.gate }
    private var clean: CleanModel { model.clean }
    private var duplicates: DuplicatesModel { model.duplicates }
    private var uninstall: UninstallModel { model.uninstall }

    private var hasConfirmation: Bool {
        clean.confirmation != nil || duplicates.confirmation != nil || uninstall.confirmation != nil
    }

    var body: some View {
        SymairaPage(
            title: CockpitDestination.storage.title, subtitle: CockpitDestination.storage.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
                volumes
                if let running = gate.running {
                    SymairaNotice(
                        title: "\(running) in Progress",
                        message: "Large jobs can take several minutes. The agent does not offer cancellation.",
                        tone: .neutral
                    )
                }
                StorageHealthCard(model: model.health)
                    .disabled(gate.isBusy || hasConfirmation)
                StorageSpaceCard(model: model.space, gate: gate, isPrimary: !hasConfirmation)
                    .disabled(hasConfirmation)
                StorageCleanCard(model: clean, gate: gate)
                    .disabled(hasConfirmation && clean.confirmation == nil)
                StorageDuplicatesCard(model: duplicates, gate: gate)
                    .disabled(hasConfirmation && duplicates.confirmation == nil)
                StorageUninstallCard(model: uninstall, gate: gate)
                    .disabled(hasConfirmation && uninstall.confirmation == nil)
                StorageSpeedtestCard(model: model.speed, gate: gate, volumes: metrics.storageVolumes ?? [])
                    .disabled(hasConfirmation)
            }
        }
        .task(id: isWindowVisible) {
            guard isWindowVisible, !gate.isBusy, !hasConfirmation else { return }
            await model.health.load()
        }
    }

    @ViewBuilder
    private var volumes: some View {
        if metrics.storageVolumes == nil, let diagnosis = metrics.diagnosis {
            PageCard(title: "Storage Volumes", icon: .storage) {
                SymairaNotice(message: diagnosis.detail, tone: .critical)
                Button("Try Again") { metrics.refreshNow() }
                    .symairaButtonStyle(.secondary)
                    .disabled(gate.isBusy || hasConfirmation)
            }
        } else {
            StorageVolumesCard(volumes: metrics.storageVolumes)
        }
    }
}

/// Keeps the status and result of an agent job available when the user returns to Storage.
@MainActor
final class StoragePageModel {
    let gate: AgentWorkGate
    let health: StorageHealthModel
    let space: SpaceModel
    let clean: CleanModel
    let duplicates: DuplicatesModel
    let uninstall: UninstallModel
    let speed: SpeedtestModel

    init(session: AgentSession) {
        let gate = AgentWorkGate()
        self.gate = gate
        health = StorageHealthModel(session: session)
        space = SpaceModel(session: session, gate: gate)
        clean = CleanModel(session: session, gate: gate)
        duplicates = DuplicatesModel(session: session, gate: gate)
        uninstall = UninstallModel(session: session, gate: gate)
        speed = SpeedtestModel(session: session, gate: gate)
    }
}

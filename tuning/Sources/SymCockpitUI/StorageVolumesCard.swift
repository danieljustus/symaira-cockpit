import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The same read-only volume list in the cockpit and menu-bar popover.
struct StorageVolumesCard: View {
    let volumes: [StorageVolumeReport]?
    var hiddenVolumeIDs: Set<String> = []
    /// Nil in passive previews: no preference object or write path is acquired.
    var visibility: ((StorageVolumeReport) -> Binding<Bool>)?

    var visibleVolumes: [StorageVolumeReport]? {
        volumes?.filter { !hiddenVolumeIDs.contains($0.selectionID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            HStack {
                Text("STORAGE VOLUMES")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTokens.ink3)
                Spacer()
                if let visibleVolumes {
                    Text("\(visibleVolumes.count)")
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTokens.ink2)
                }
                selectionMenu
            }

            if let visibleVolumes {
                if visibleVolumes.isEmpty {
                    statusText(volumes?.isEmpty == true
                        ? "No mounted storage volumes found"
                        : "No volumes selected. Use Choose… to show volumes.")
                }
                ForEach(visibleVolumes) { volume in
                    volumeRow(volume)
                }
                if !visibleVolumes.isEmpty {
                    statusText("Available space can include purgeable data. APFS volumes may share capacity.")
                }
            } else {
                statusText("Loading storage volumes…")
            }
        }
        .cardStyle()
        .accessibilityIdentifier("storage-volumes")
    }

    @ViewBuilder
    private var selectionMenu: some View {
        if let volumes, !volumes.isEmpty, let visibility {
            Menu {
                ForEach(volumes) { volume in
                    Toggle("\(volume.name) (\(volume.mountPath))", isOn: visibility(volume))
                        .accessibilityLabel("Show \(volume.name) at \(volume.mountPath) in the panel")
                        .accessibilityIdentifier("show-storage-volume:\(volume.id)")
                }
            } label: {
                Text("Choose…")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.selected)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Choose storage volumes")
            .accessibilityIdentifier("storage-volume-selection")
            .help("Choose which storage volumes appear in both panels. Selection is saved automatically.")
        }
    }

    private func volumeRow(_ volume: StorageVolumeReport) -> some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            HStack(spacing: SymairaSpacing.small) {
                Image(systemName: volume.isInternal == true ? "internaldrive" : "externaldrive")
                    .foregroundStyle(SymairaTokens.selected)
                    .accessibilityHidden(true)
                Text(volume.name)
                    .symairaText(.body, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(volume.name)
                Spacer(minLength: SymairaSpacing.xSmall)
            }
            statusText(volume.kind + (volume.isReadOnly == true ? " · Read-only" : ""))
            Text(volume.mountPath)
                .symairaText(.monoSmall)
                .foregroundStyle(SymairaTokens.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(volume.mountPath)
            if let fraction = volume.usedFraction {
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? SymairaTokens.warning : SymairaTokens.selected)
                    .accessibilityLabel("Storage used on \(volume.name)")
                    .accessibilityValue(String(format: "%.0f%%", fraction * 100))
            }
            Text(volume.capacitySummary)
                .symairaText(.caption, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage-volume:\(volume.id)")
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .symairaText(.caption, respectsForeground: false)
            .foregroundStyle(SymairaTokens.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

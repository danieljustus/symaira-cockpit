import SwiftUI
import SymairaTheme
import SymTuneCore

/// What the HUD shows, where, and when.
///
/// Three decisions per readout, and they are genuinely three: **on or off**,
/// **which side** it sits on, and **how far the HUD has to be open** before it
/// turns up. The last one is the reason this card exists at all — with a peek
/// between parked and open, "show this" stopped being a yes/no question and
/// became a question about *when*.
///
/// It sits beside ``MenuBarVisibilityCard`` rather than inside it, and only
/// when the HUD is the chosen readout surface. The two cards answer the same
/// shape of question about two different surfaces, and merging them produced a
/// single list where half the switches did nothing depending on a picker four
/// rows further up.
///
/// Everything here writes to `UserDefaults` through ``HUDItemPreferences`` and
/// takes effect on the HUD immediately — there is no Apply button, because
/// there is nothing to apply it to but a shape the user is looking at.
@MainActor
struct HUDContentCard: View {
    @ObservedObject var items: HUDItemPreferences
    @ObservedObject var preferences: PreferencesManager
    /// The dock the HUD is parked in. The left/right choice means two shoulders
    /// on the notch and two columns in the card; on an edge dock it only sorts
    /// the single column, and the caption says so rather than letting the user
    /// wonder why nothing moved.
    let dock: HUDDock

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            header

            VStack(spacing: SymairaSpacing.xSmall) {
                columnHeaders
                ForEach(HUDItemKind.allCases, id: \.rawValue) { kind in
                    itemRow(kind)
                }
            }

            footnote
        }
        .cardStyle()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HUD CONTENT")
                    .symairaText(.sectionLabel)
                    .foregroundStyle(SymairaTheme.goldPrimary)
                Text("What the HUD shows, and how far it has to be open")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            Spacer(minLength: SymairaSpacing.small)
            Button("Reset") { items.resetToDefault() }
                .buttonStyle(.link)
                .symairaText(.caption)
                .help("Back to the readouts the HUD ships with")
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: SymairaSpacing.medium) {
            Spacer(minLength: 0)
            Text("Side")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textMuted)
                .frame(width: Self.sideWidth)
            Text("Show")
                .symairaText(.caption)
                .foregroundStyle(SymairaTheme.textMuted)
                .frame(width: Self.stageWidth)
            Color.clear.frame(width: Self.toggleWidth, height: 1)
        }
    }

    private static let sideWidth: CGFloat = 96
    private static let stageWidth: CGFloat = 132
    private static let toggleWidth: CGFloat = 44

    // MARK: - Rows

    private func itemRow(_ kind: HUDItemKind) -> some View {
        let placement = items.layout.placement(for: kind)
        // A metric nobody is sampling has nothing to put on the HUD. The row
        // stays usable — the placement is still worth setting up — but it says
        // why the HUD is not showing it, rather than looking broken.
        let unmonitored = kind.requiresMonitoring
            && !(kind.metric.map { preferences.enabledMetrics.contains($0) } ?? true)

        return HStack(spacing: SymairaSpacing.medium) {
            Image(systemName: kind.symbolName)
                .symairaText(.caption)
                .frame(width: 18)
                .foregroundStyle(placement.isEnabled ? SymairaTheme.goldPrimary : SymairaTheme.textMuted)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .symairaText(.body)
                    .foregroundStyle(placement.isEnabled ? SymairaTheme.textPrimary : SymairaTheme.textMuted)
                if placement.isEnabled, unmonitored {
                    Text("Not monitored — turn it on above")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }

            Spacer(minLength: SymairaSpacing.small)

            Picker("", selection: sideBinding(kind)) {
                ForEach(HUDItemSide.allCases, id: \.rawValue) { side in
                    Text(side.displayName).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: Self.sideWidth)
            .disabled(!placement.isEnabled)
            .opacity(placement.isEnabled ? 1 : 0.4)
            .help(sideHelp)

            Picker("", selection: stageBinding(kind)) {
                ForEach(HUDPresentation.allCases, id: \.rawValue) { stage in
                    Text(stage.displayName).tag(stage)
                }
            }
            .labelsHidden()
            .frame(width: Self.stageWidth)
            .disabled(!placement.isEnabled)
            .opacity(placement.isEnabled ? 1 : 0.4)
            .help(placement.stage.settingsCaption)

            Toggle("", isOn: enabledBinding(kind))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(SymairaTheme.goldPrimary)
                .frame(width: Self.toggleWidth)
                .help("Show \(kind.displayName) on the HUD")
        }
    }

    /// What the side picker does depends on where the HUD is parked, and the
    /// tooltip is the honest place to say so.
    private var sideHelp: String {
        dock == .notch
            ? "Which shoulder of the cutout this sits on"
            : "Sort order in the edge HUD's card — the sliver has one column"
    }

    // MARK: - Footnotes

    /// Two things worth saying before the user goes looking for them on the
    /// notch: that a stage they have emptied will look like nothing happened,
    /// and that the parked shoulders are narrow whatever they put there.
    @ViewBuilder
    private var footnote: some View {
        let notes = warnings
        if !notes.isEmpty {
            Divider().overlay(SymairaTheme.borderGlass)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var warnings: [String] {
        var notes: [String] = []
        if !items.layout.hasItems(at: .collapsed) {
            notes.append("Nothing is set to “Always”, so the parked HUD shows no readout.")
        }
        if !items.layout.hasItems(at: .expanded) {
            notes.append("Nothing is switched on, so the HUD stays empty.")
        } else if items.layout.items(at: .peek) == items.layout.items(at: .expanded) {
            notes.append("Nothing is set to “When opened”, so clicking the HUD adds no readouts.")
        }
        if dock == .notch, items.layout.items(on: .left, at: .collapsed).count > 2
            || items.layout.items(on: .right, at: .collapsed).count > 2 {
            notes.append("A parked shoulder fits about two readouts; the rest are clipped until you hover.")
        }
        return notes
    }

    // MARK: - Bindings

    /// Each binding reads and rewrites the whole placement, so a change to one
    /// axis cannot drop the other two.
    private func enabledBinding(_ kind: HUDItemKind) -> Binding<Bool> {
        Binding(
            get: { items.layout.placement(for: kind).isEnabled },
            set: { newValue in
                var placement = items.layout.placement(for: kind)
                placement.isEnabled = newValue
                items.layout.set(placement, for: kind)
            }
        )
    }

    private func sideBinding(_ kind: HUDItemKind) -> Binding<HUDItemSide> {
        Binding(
            get: { items.layout.placement(for: kind).side },
            set: { newValue in
                var placement = items.layout.placement(for: kind)
                placement.side = newValue
                items.layout.set(placement, for: kind)
            }
        )
    }

    private func stageBinding(_ kind: HUDItemKind) -> Binding<HUDPresentation> {
        Binding(
            get: { items.layout.placement(for: kind).stage },
            set: { newValue in
                var placement = items.layout.placement(for: kind)
                placement.stage = newValue
                items.layout.set(placement, for: kind)
            }
        )
    }
}

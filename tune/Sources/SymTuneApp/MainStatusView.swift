import SwiftUI
import SymTuneCore
import SymairaTheme
import SymairaUpdateCheck

/// The status popover.
///
/// This view is deliberately thin: it only assembles cards and hands each one
/// the slice of model state it needs. All heavy lifting — hardware polling,
/// aggregation, formatting — happens in ``TuneViewModel`` once per refresh, and
/// the cards below are `Equatable` so an unchanged card is not re-rendered.
///
/// ## Why the sections are separate views
/// Reading `model.sensors` (or any other polled property) *here* would make
/// SwiftUI re-evaluate this whole body — all nine cards — on every tick, even
/// though the `Equatable` cards then skip their own subtrees. Each polled
/// property is therefore read inside the smallest view that needs it, so a
/// metrics tick invalidates one section instead of the panel.
///
/// ## Layout
/// Two groups with a label each — controls the user acts on, then read-only
/// insight — so the panel scans as two short lists rather than one long stack.
@MainActor
struct MainStatusView: View {
    let controller: TuneController
    let model: TuneViewModel
    let aiUsageModel: AIUsageViewModel
    let processesModel: ProcessesViewModel
    @ObservedObject var updateChecker: AppUpdateChecker
    @ObservedObject var preferencesManager: PreferencesManager
    let openPreferences: () -> Void

    /// Height budget for the popover, from the screen the menu bar is on.
    /// The panel grows with its content up to this cap and scrolls beyond it —
    /// `NSPopover` neither reflows nor scrolls oversized content, it just
    /// positions the window so the overflow (header first) falls off-screen.
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            cards
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)
        .background(SymairaTheme.bgDark)
    }

    private var cards: some View {
        VStack(spacing: SymairaSpacing.medium) {
            StatusHeaderView()
            LiveSummaryStrip(model: model)

            // Never hidden: an available update is the one thing the user has
            // not opted out of seeing.
            UpdateNotificationView(updateChecker: updateChecker)

            if showsAnyControl {
                GroupLabel("CONTROLS")
            }

            if shows(.displayControls) {
                DisplayControlsCard(controller: controller, model: model)
            }

            if shows(.keepAwake) {
                KeepAwakeSection(controller: controller, model: model)
            }

            if shows(.fanControl, hardwareAvailable: hasFans) {
                FanControlCard(controller: controller, model: model)
            }

            GroupLabel("SYSTEM")

            if shows(.topProcesses) {
                TopProcessesCard(model: processesModel)
            }

            if shows(.systemStatus) {
                SystemStatusSection(model: model)
            }

            // AI usage meters for the enabled providers (no card when none
            // are enabled — an all-off preference set shows nothing).
            if !aiUsageModel.rows.isEmpty {
                AIUsageCardView(model: aiUsageModel)
            }

            if shows(.metricsHistory) {
                MetricsHistorySection(model: model)
            }

            if shows(.displays) {
                DisplaysSection(model: model)
            }

            StatusFooterView(openPreferences: openPreferences)
        }
        .padding(SymairaSpacing.medium)
        .frame(width: 320)
    }

    // MARK: - Card visibility

    private func shows(_ card: PopoverCard, hardwareAvailable: Bool = true) -> Bool {
        preferencesManager.showsCard(card, hardwareAvailable: hardwareAvailable)
    }

    private var showsAnyControl: Bool {
        shows(.displayControls) || shows(.keepAwake) || shows(.fanControl, hardwareAvailable: hasFans)
    }

    /// Whether this Mac reports any fan. `nil` sensors means "not read yet" —
    /// treated as present so the card does not flicker away on the first frame
    /// and back once the first sensor read lands.
    private var hasFans: Bool {
        guard let fans = model.sensors?.fans else { return true }
        return !fans.isEmpty
    }
}

// MARK: - Group label

/// A quiet divider-with-a-name between the two halves of the panel.
private struct GroupLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            Text(title)
                .symairaText(.sectionLabel)
                .foregroundStyle(SymairaTheme.goldSecondary.opacity(0.8))
            Rectangle()
                .fill(SymairaTheme.goldPrimary.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.horizontal, SymairaSpacing.xSmall)
    }
}

// MARK: - Sections
//
// One polled property per section, so a tick invalidates only what changed.

/// Battery + thermal readout.
private struct SystemStatusSection: View {
    let model: TuneViewModel

    var body: some View {
        SystemStatusCard(battery: model.battery, sensors: model.sensors)
            .equatable()
    }
}

/// Sparkline history for the enabled metrics.
private struct MetricsHistorySection: View {
    let model: TuneViewModel

    var body: some View {
        MetricsHistoryCard(rows: model.metricRows)
            .equatable()
    }
}

/// Attached displays and their EDR headroom.
private struct DisplaysSection: View {
    let model: TuneViewModel

    var body: some View {
        DisplaysCard(displays: model.displays)
            .equatable()
    }
}

/// Keep-awake card plus the duration/display-sleep choices it owns.
private struct KeepAwakeSection: View {
    let controller: TuneController
    let model: TuneViewModel

    /// Duration presets: indefinite + 15m, 30m, 1h, 2h, 4h, 8h
    private static let presets: [(label: String, seconds: TimeInterval?)] = [
        ("Indefinite", nil),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600),
        ("2 hours", 7200),
        ("4 hours", 14400),
        ("8 hours", 28800),
    ]

    @State private var durationIndex = 0
    @State private var preventDisplaySleep = false

    var body: some View {
        KeepAwakeCard(
            active: model.keepAwake.active,
            preventDisplaySleep: $preventDisplaySleep,
            durationIndex: $durationIndex,
            remaining: remaining,
            isInteractive: !model.keepAwake.active,
            presets: Self.presets,
            onToggle: toggle
        )
        .onAppear { preventDisplaySleep = model.keepAwake.preventDisplaySleep }
    }

    private var remaining: String? {
        let session = model.keepAwake
        guard session.active, let expiresAt = session.expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "expiring…" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func toggle() {
        if model.keepAwake.active {
            controller.endKeepAwakeSession()
        } else {
            _ = try? controller.beginKeepAwakeSession(
                duration: Self.presets[durationIndex].seconds,
                preventDisplaySleep: preventDisplaySleep,
                reason: "SymairaTune menu bar"
            )
        }
        model.refreshNow()
    }
}

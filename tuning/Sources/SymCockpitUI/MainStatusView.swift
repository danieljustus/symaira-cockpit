import SwiftUI
import SymCockpitCore
import SymairaTheme
import SymairaUpdateCheck

/// The status popover: the compact panel that hangs off the menu bar.
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
/// The cockpit window does not embed this view: its pages (`Cockpit*Page`) compose
/// the same cards, so nothing is built twice and the popover stays the compact panel.
/// What the cards are drawn for.
///
/// The popover is a 320pt window hanging off the menu bar; the cockpit window shows
/// the same cards at page width. The cards read this to size their padding and rows.
public enum TunePanelChrome: Sendable {
    /// Fixed-width column with the app header and the preferences footer.
    case popover
    /// Page width inside the cockpit window.
    case embedded
}

@MainActor
struct MainStatusView: View {
    let model: TuneViewModel
    /// The user's config.toml, for the bounds of the brightness controls.
    let config: TuneConfig
    let aiUsageModel: AIUsageViewModel
    let processesModel: ProcessesViewModel
    @ObservedObject var updateChecker: AppUpdateChecker
    @ObservedObject var preferencesManager: PreferencesManager
    let openPreferences: () -> Void

    /// When set (cockpit host), the left-click popover shows a visible
    /// "Open Cockpit…" row so the window is reachable without knowing about
    /// the right-click context menu. Nil in the standalone Tune app.
    var onOpenCockpit: (() -> Void)? = nil

    /// Title of the ``onOpenCockpit`` row inside the popover.
    var openCockpitTitle: String = "Open Cockpit…"

    /// Header title and version line (branding override — see
    /// ``StatusHeaderView``).
    var panelTitle: String = "SYMAIRA COCKPIT"
    var panelVersion: String = TuneVersion.current

    /// Height budget for the popover, from the screen the menu bar is on.
    /// The panel grows with its content up to this cap and scrolls beyond it —
    /// `NSPopover` neither reflows nor scrolls oversized content, it just
    /// positions the window so the overflow (header first) falls off-screen.
    let maxHeight: CGFloat

    /// Who answers the brightness keys, and the tap behind the choice. Nil in
    /// a host that does not offer the takeover (issue #250).
    var brightnessKeyPreferences: BrightnessKeyPreferences? = nil
    var brightnessKeyController: BrightnessKeyController? = nil

    var body: some View {
        ScrollView(.vertical) {
            cards
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)
        .background(SymairaTokens.canvas)
    }

    private var cards: some View {
        VStack(spacing: SymairaSpacing.medium) {
            StatusHeaderView(title: panelTitle, version: panelVersion)
            if let onOpenCockpit {
                openCockpitRow(onOpenCockpit)
            }
            // Why nothing is measured, when the agent is not running: a diagnosis, never a stale value.
            if let diagnosis = model.diagnosis {
                AgentDiagnosisCard(diagnosis: diagnosis, restart: { model.restartAgent() })
            }
            LiveSummaryStrip(model: model)

            // Never hidden: an available update is the one thing the user has
            // not opted out of seeing.
            UpdateNotificationView(updateChecker: updateChecker)

            VStack(spacing: SymairaSpacing.medium) {
                if showsAnyControl {
                    controlCards
                }
                if showsAnySystem {
                    systemCards
                }
            }

            StatusFooterView(openPreferences: openPreferences)
        }
        .padding(SymairaSpacing.medium)
        .frame(maxWidth: 320)
        // Follows the system appearance; every colour is an adaptive Liquid
        // Topography role (design pilot revision 08).
        .tint(SymairaTokens.selected)
        .environment(\.tunePanelChrome, .popover)
    }

    private var controlCards: some View {
        VStack(spacing: SymairaSpacing.medium) {
            VStack(spacing: SymairaSpacing.medium) {
                GroupLabel("CONTROLS")
                if shows(.displayControls) {
                    DisplayControlsCard(
                        model: model,
                        config: config,
                        brightnessKeys: brightnessKeyPreferences,
                        brightnessKeyController: brightnessKeyController
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            VStack(spacing: SymairaSpacing.medium) {
                if shows(.keepAwake) {
                    KeepAwakeSection(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if shows(.fanControl, hardwareAvailable: hasFans) {
                    FanControlCard(
                        model: model,
                        preferencesManager: preferencesManager,
                        openPreferences: openPreferences
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var systemCards: some View {
        VStack(spacing: SymairaSpacing.medium) {
            GroupLabel("SYSTEM")
            if shows(.systemStatus) {
                SystemStatusSection(model: model)
            }
            if shows(.topProcesses) {
                TopProcessesCard(model: processesModel)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if shows(.storageVolumes) {
                StorageVolumesSection(model: model, preferences: preferencesManager)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !aiUsageModel.providers.isEmpty {
                AIUsageCardView(model: aiUsageModel)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if shows(.metricsHistory) {
                MetricsHistorySection(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if shows(.displays) {
                DisplaysSection(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Card visibility

    /// Visible "Open Cockpit…" row for the left-click popover: the cockpit
    /// window must be reachable from the status item's primary interaction,
    /// not only from a right-click context menu most users never try.
    private func openCockpitRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SymairaIconView(.window, size: 16)
                    .foregroundStyle(SymairaTokens.selected)
                Text(openCockpitTitle)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink)
                Spacer()
                SymairaIconView(.openExternal, size: 14)
                    .foregroundStyle(SymairaTokens.ink3)
            }
            .padding(.horizontal, SymairaSpacing.medium)
            .padding(.vertical, SymairaSpacing.small)
            .background(SymairaTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.card)
                    .stroke(SymairaTokens.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SymairaSpacing.xSmall)
    }

    private func shows(_ card: PopoverCard, hardwareAvailable: Bool = true) -> Bool {
        preferencesManager.showsCard(card, hardwareAvailable: hardwareAvailable)
    }

    private var showsAnyControl: Bool {
        shows(.displayControls) || shows(.keepAwake) || shows(.fanControl, hardwareAvailable: hasFans)
    }

    private var showsAnySystem: Bool {
        shows(.systemStatus) || shows(.topProcesses) || shows(.metricsHistory)
            || shows(.storageVolumes) || shows(.displays) || !aiUsageModel.providers.isEmpty
    }

    /// Whether this Mac reports any fan. `nil` sensors means "not read yet",
    /// and an unsupported SMC connection means "unknown, not measured" —
    /// both treated as present so the card does not disappear just because
    /// the read that would confirm fans is itself blocked. On at least one
    /// real machine, `SMCService.isAvailable`'s read-only probe fails when
    /// unprivileged even though the hardware and the write path both work
    /// fine once elevated (see ``PrivilegedElevation``); treating that as
    /// "no fans" would hide the one card that could otherwise recover via
    /// escalation. Only a genuinely successful read reporting zero fans
    /// hides the card.
    private var hasFans: Bool { model.hasFans }
}

// MARK: - Group label

/// A quiet divider-with-a-name between the two halves of the panel.
struct GroupLabel: View {
    let title: String
    @Environment(\.tunePanelChrome) private var chrome

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            Text(title)
                .symairaText(chrome == .embedded ? .heading : .sectionLabel, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink)
                .cockpitProtected()
            Rectangle()
                .fill(SymairaTokens.line)
                .frame(height: 1)
        }
        .padding(.horizontal, SymairaSpacing.xSmall)
    }
}

// MARK: - Sections
//
// One polled property per section, so a tick invalidates only what changed.

/// Battery + thermal readout.
struct SystemStatusSection: View {
    let model: TuneViewModel

    var body: some View {
        SystemStatusCard(battery: model.battery, sensors: model.sensors)
            .equatable()
    }
}

/// Sparkline history for the enabled metrics.
struct MetricsHistorySection: View {
    let model: TuneViewModel

    var body: some View {
        MetricsHistoryCard(rows: model.metricRows)
            .equatable()
    }
}

/// Attached displays and their EDR headroom.
struct DisplaysSection: View {
    let model: TuneViewModel

    var body: some View {
        DisplaysCard(displays: model.displays)
            .equatable()
    }
}

/// Observes only the volume list, not every CPU/network metrics tick.
struct StorageVolumesSection: View {
    let model: TuneViewModel
    @ObservedObject var preferences: PreferencesManager

    var body: some View {
        StorageVolumesCard(
            volumes: model.storageVolumes,
            hiddenVolumeIDs: preferences.hiddenStorageVolumeIDs,
            visibility: { preferences.storageVolumeVisibility(for: $0) }
        )
    }
}

/// Keep-awake card plus the duration/display-sleep choices it owns.
struct KeepAwakeSection: View {
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
    @State private var awakeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            KeepAwakeCard(
                active: model.keepAwake.active,
                preventDisplaySleep: $preventDisplaySleep,
                durationIndex: $durationIndex,
                remaining: remaining,
                isInteractive: !model.keepAwake.active,
                presets: Self.presets,
                onToggle: toggle
            )
            if let awakeError {
                Text(awakeError)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .cockpitProtected()
            }
        }
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
        let wasActive = model.keepAwake.active
        let duration = Self.presets[durationIndex].seconds
        let preventDisplaySleep = preventDisplaySleep
        Task {
            let outcome = await model.setKeepAwake(!wasActive, preventDisplaySleep: preventDisplaySleep, duration: duration)
            awakeError = outcome.failureMessage.map(SecretRedactor.redact)
        }
    }
}

/// The HUD placement card, and the decision to show it at all.
///
/// A view of its own purely so the three preference objects can be held as
/// `@ObservedObject`. They arrive at ``MainStatusView`` as optionals — the
/// standalone Tune app has no HUD to configure — and an optional
/// `ObservableObject` cannot be observed, so read through the parent's `var`
/// the card would keep rendering the surface, dock and placement it was built
/// with rather than the ones the user is changing in front of it.
@MainActor
struct HUDContentSection: View {
    @ObservedObject var readout: ReadoutSurfacePreferences
    @ObservedObject var dock: HUDDockPreferences
    @ObservedObject var items: HUDItemPreferences
    @ObservedObject var preferences: PreferencesManager

    var body: some View {
        // Only while the HUD is the chosen surface. Three pickers per readout
        // is a lot of card to show somebody who is looking at the menu bar.
        if readout.surface == .notch {
            HUDContentCard(items: items, preferences: preferences, dock: dock.dock)
        }
    }
}

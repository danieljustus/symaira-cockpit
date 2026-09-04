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
/// Where the panel is being rendered.
///
/// The popover is a 320pt window hanging off the menu bar; the cockpit is a
/// resizable window with its own title, sidebar and footer. The cards are the
/// same in both — what differs is the chrome around them, and a panel that
/// carries its popover chrome into a window reads as an embedded popover
/// rather than as part of the window.
public enum TunePanelChrome: Sendable {
    /// Fixed-width column with the app header and the preferences footer.
    case popover
    /// Fills its container; the host window supplies title, footer and
    /// scrolling. Adds the menu-bar visibility card, which the popover leaves
    /// to the Preferences window for want of vertical space.
    case embedded
}

@MainActor
struct MainStatusView: View {
    let controller: TuneController
    let model: TuneViewModel
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
    var panelTitle: String = "SYMAIRA TUNE"
    var panelVersion: String = TuneVersion.current

    /// Reason string for the Keep Awake power assertion (branding override).
    var keepAwakeAssertionReason: String = "SymairaTune menu bar"

    /// Height budget for the popover, from the screen the menu bar is on.
    /// The panel grows with its content up to this cap and scrolls beyond it —
    /// `NSPopover` neither reflows nor scrolls oversized content, it just
    /// positions the window so the overflow (header first) falls off-screen.
    let maxHeight: CGFloat

    /// Popover or embedded — see ``TunePanelChrome``.
    var chrome: TunePanelChrome = .popover

    var body: some View {
        switch chrome {
        case .popover:
            ScrollView(.vertical) {
                cards
            }
            .frame(width: 320)
            .frame(maxHeight: maxHeight)
            .background(SymairaTheme.bgDark)
        case .embedded:
            // No scroll view and no background: the cockpit window owns both,
            // and nesting a second scroll view inside its own would trap the
            // wheel over half the page.
            cards
        }
    }

    private var cards: some View {
        VStack(spacing: SymairaSpacing.medium) {
            if chrome == .popover {
                StatusHeaderView(title: panelTitle, version: panelVersion)
                if let onOpenCockpit {
                    openCockpitRow(onOpenCockpit)
                }
            }
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
                KeepAwakeSection(controller: controller, model: model, assertionReason: keepAwakeAssertionReason)
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

            if chrome == .embedded {
                // No GroupLabel here: the card carries its own "MENU BAR"
                // heading, and the two together read as a stutter.
                MenuBarVisibilityCard(
                    preferences: preferencesManager,
                    aiUsage: aiUsageModel.preferences,
                    model: model,
                    hasEnabledAIProviders: !aiUsageModel.rows.isEmpty
                )
            }

            if chrome == .popover {
                StatusFooterView(openPreferences: openPreferences)
            }
        }
        .padding(chrome == .popover ? SymairaSpacing.medium : 0)
        .frame(maxWidth: chrome == .popover ? 320 : .infinity)
    }

    // MARK: - Card visibility

    /// Visible "Open Cockpit…" row for the left-click popover: the cockpit
    /// window must be reachable from the status item's primary interaction,
    /// not only from a right-click context menu most users never try.
    private func openCockpitRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                    .foregroundStyle(SymairaTheme.goldPrimary)
                Text(openCockpitTitle)
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            .padding(.horizontal, SymairaSpacing.medium)
            .padding(.vertical, SymairaSpacing.small)
            .background(SymairaTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.card)
                    .stroke(SymairaTheme.borderGlass, lineWidth: 1)
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
    private var hasFans: Bool {
        guard let sensors = model.sensors else { return true }
        guard sensors.smcSupported else { return true }
        return !sensors.fans.isEmpty
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
    let assertionReason: String

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
                reason: assertionReason
            )
        }
        model.refreshNow()
    }
}

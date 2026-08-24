import SwiftUI
import SymairaTheme
import SymTuneUI

/// The cockpit window's content: a sidebar of the three families plus an
/// overview, and the selected section on the right.
///
/// Each section reads from the same source the CLI does — Tune from the shared
/// ``StatusBarController`` model, Scope from `SymScopeCore`, Operate from
/// `SymOperateCore` — so the window never shows a number the shell would
/// disagree with.
@MainActor
struct CockpitRootView: View {
    let statusBar: StatusBarController
    @ObservedObject var scope: ScopeViewModel
    @ObservedObject var operate: OperateViewModel
    let openPreferences: () -> Void

    /// The selected section survives a relaunch — a menu-bar app gets opened
    /// and closed constantly, and landing back on the overview every time
    /// makes the window feel like it forgot what you were doing.
    @AppStorage("com.symaira.cockpit.section") private var sectionID: String = CockpitSection.overview.rawValue

    private var section: CockpitSection {
        get { CockpitSection(rawValue: sectionID) ?? .overview }
        nonmutating set { sectionID = newValue.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(SymairaTheme.borderGlass)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(SymairaTheme.bgDark)
        }
        .background(SymairaTheme.bgDarker)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The window title is drawn here rather than left to the title
                // bar so it sits on the dark chrome instead of the system's
                // light strip.
                Text(section.title)
                    .font(SymairaTypography.subheading)
                    .foregroundStyle(SymairaTheme.textPrimary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshCurrentSection()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(section == .tune)
                .help(section == .tune ? "Tune refreshes on its own clock" : "Refresh this section (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openPreferences()
                } label: {
                    Label("Preferences", systemImage: "gearshape")
                }
                .help("Open Tune preferences (⌘,)")
            }
        }
        // ⌘1…⌘4 jump straight to a section. The buttons are invisible and
        // zero-sized; they exist only to own the shortcuts, because a
        // status-bar app's main menu has nowhere natural to hang them.
        .background {
            ForEach(Array(CockpitSection.allCases.enumerated()), id: \.element) { index, item in
                Button("") { section = item }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: .command
                    )
                    .hidden()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("COCKPIT")
                .font(SymairaTypography.micro)
                .kerning(1.2)
                .foregroundStyle(SymairaTheme.textMuted)
                .padding(.horizontal, SymairaSpacing.medium)
                .padding(.top, SymairaSpacing.small)
                .padding(.bottom, SymairaSpacing.xSmall)

            ForEach(Array(CockpitSection.allCases.enumerated()), id: \.element) { index, item in
                CockpitSidebarRow(
                    section: item,
                    shortcut: index + 1,
                    isSelected: section == item,
                    action: { section = item }
                )
            }

            Spacer(minLength: SymairaSpacing.large)

            VStack(alignment: .leading, spacing: 2) {
                Text("Symaira Cockpit \(CockpitAppVersion.current)")
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textSecondary)
                Text("Menu bar stays live when this window closes.")
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SymairaSpacing.medium)
        }
        .frame(width: 208, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SymairaTheme.bgDarker)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview:
            OverviewView(scope: scope, operate: operate, openSection: { section = $0 })
        case .tune:
            TuneSectionView(statusBar: statusBar, openPreferences: openPreferences)
        case .scope:
            ScopeView(model: scope)
        case .operate:
            OperateView(model: operate)
        }
    }

    /// ⌘R means "refresh what I am looking at". Tune polls on its own clock,
    /// so there it is a no-op rather than a second, competing refresh path.
    private func refreshCurrentSection() {
        switch section {
        case .overview:
            scope.refreshNow()
            operate.refresh()
        case .scope:
            scope.refreshNow()
        case .operate:
            operate.refresh()
        case .tune:
            break
        }
    }
}

/// One sidebar entry: icon, title, and the ⌘-number that selects it.
private struct CockpitSidebarRow: View {
    let section: CockpitSection
    let shortcut: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SymairaSpacing.small) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? SymairaTheme.goldPrimary : SymairaTheme.textSecondary)
                Text(section.title)
                    .font(SymairaTypography.bodyMedium)
                    .foregroundStyle(isSelected ? SymairaTheme.textPrimary : SymairaTheme.textSecondary)
                Spacer(minLength: SymairaSpacing.small)
                Text("⌘\(shortcut)")
                    .font(SymairaTypography.micro)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .opacity(isHovered || isSelected ? 1 : 0)
            }
            .padding(.horizontal, SymairaSpacing.small)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SymairaRadius.control, style: .continuous)
                    .fill(background)
            )
            .overlay(alignment: .leading) {
                // A gold rule on the selected row, so the selection survives
                // the window losing focus (a system highlight would grey out).
                RoundedRectangle(cornerRadius: 1)
                    .fill(SymairaTheme.goldPrimary)
                    .frame(width: 2, height: 16)
                    .opacity(isSelected ? 1 : 0)
                    .offset(x: -4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SymairaSpacing.medium)
        .padding(.vertical, 1)
        .onHover { isHovered = $0 }
        .help("\(section.title) (⌘\(shortcut))")
    }

    private var background: Color {
        if isSelected { return SymairaTheme.goldPrimary.opacity(0.12) }
        return isHovered ? SymairaTheme.bgCardHover : .clear
    }
}

/// The sections of the cockpit window — the overview plus one per CLI family.
enum CockpitSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case tune
    case scope
    case operate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .tune: return "Tune"
        case .scope: return "Scope"
        case .operate: return "Operate"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tune: return "slider.horizontal.3"
        case .scope: return "network"
        case .operate: return "cursorarrow.rays"
        }
    }

    /// One line on what the section is for, shown on its overview card.
    var blurb: String {
        switch self {
        case .overview: return ""
        case .tune: return "Thermals, power, display — the same panel as the menu bar"
        case .scope: return "Ports, containers, MCP servers"
        case .operate: return "GUI automation readiness"
        }
    }

    /// The `symcockpit` subcommand this section corresponds to, shown so the
    /// window doubles as a discovery surface for the CLI.
    var command: String? {
        switch self {
        case .overview: return nil
        case .tune: return "symcockpit tune"
        case .scope: return "symcockpit scope"
        case .operate: return "symcockpit operate"
        }
    }
}

import SwiftUI
import SymCockpitCore
import SymairaTheme

private struct TunePanelChromeKey: EnvironmentKey {
    static let defaultValue: TunePanelChrome = .popover
}

extension EnvironmentValues {
    var tunePanelChrome: TunePanelChrome {
        get { self[TunePanelChromeKey.self] }
        set { self[TunePanelChromeKey.self] = newValue }
    }
}

extension View {
    func cockpitProtected(hill: Bool = false) -> some View {
        topoProtected(hill: hill)
    }
}

/// Which page the window shows. The AppKit host owns it, so the main menu's
/// Navigate items (⌘1 to ⌘9) and the sidebar act on the same selection.
@MainActor
@Observable
public final class CockpitNavigation {
    public var selection: CockpitDestination
    public var isWindowVisible = false

    public init(selection: CockpitDestination = .overview) {
        self.selection = selection
    }
}

/// Native workspace chrome shared by the live window and the isolated preview:
/// the Symaira shell with one sidebar destination per area and one mounted page at a
/// time. While the agent cannot serve, the page area shows that (starting, or the
/// diagnosis with a restart) instead of readings (STATE-4).
public struct CockpitWorkspaceView<Page: View>: View {
    let version: String
    let openPreferences: () -> Void
    let navigation: CockpitNavigation
    let agent: CockpitAgentStatus
    let page: (CockpitDestination) -> Page
    @Bindable private var appearance: CockpitAppearancePreferences

    @State private var sidebarLayout = SymairaSidebarState()
    @State private var topography = SymairaTopoModel()

    public init(
        version: String,
        openPreferences: @escaping () -> Void,
        appearance: CockpitAppearancePreferences = CockpitAppearancePreferences(),
        navigation: CockpitNavigation = CockpitNavigation(),
        agent: CockpitAgentStatus = CockpitAgentStatus(fixed: .ready(version: "")),
        @ViewBuilder page: @escaping (CockpitDestination) -> Page
    ) {
        self.version = version
        self.openPreferences = openPreferences
        self.appearance = appearance
        self.navigation = navigation
        self.agent = agent
        self.page = page
    }

    private var showsLabels: Bool { sidebarLayout.showsLabels }

    public var body: some View {
        SymairaWorkspace(
            sidebar: $sidebarLayout,
            // The topography belongs to the overview only (SHELL-8).
            topography: navigation.selection == .overview ? topography : nil,
            navigation: { _ in sidebar },
            content: { content }
        )
        // The sidebar toggle lives in the window toolbar, like System
        // Settings — a dedicated header row under the title bar only
        // duplicated the title and the sidebar's own navigation.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SymairaSidebarToggle(sidebar: $sidebarLayout)
            }
            ToolbarItem(placement: .primaryAction) {
                SymairaSettingsButton(openSettings: openPreferences)
                    .accessibilityIdentifier("cockpit-settings-menu")
            }
        }
        .tint(SymairaTokens.selected)
        .onAppear(perform: appearance.apply)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let selection = navigation.selection
        switch agent.phase {
        case .starting:
            SymairaPage(title: selection.title, subtitle: selection.subtitle, maxWidth: CockpitLayout.pageWidth) {
                SymairaPageState<Int, EmptyView>(
                    state: .loading, loading: "Starting the Cockpit agent…", retry: {}, loaded: { _ in EmptyView() }
                )
            }
        case .failed(let diagnosis):
            SymairaPage(title: selection.title, subtitle: selection.subtitle, maxWidth: CockpitLayout.pageWidth) {
                AgentDiagnosisCard(diagnosis: diagnosis, restart: { agent.restart() })
            }
        case .ready:
            // One mounted page per destination: switching rebuilds only the page, never the shell.
            page(selection)
                .environment(\.tunePanelChrome, .embedded)
                .id(selection)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: showsLabels ? .leading : .center, spacing: SymairaSpacing.large) {
            HStack(spacing: SymairaSpacing.small) {
                SymairaIconView(.productCockpit, size: 24)
                    .foregroundStyle(SymairaTokens.ink2)
                    .frame(width: 32, height: 36)
                    .accessibilityHidden(true)
                if showsLabels {
                    Text("Cockpit")
                        .symairaText(.heading, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink)
                }
            }
            .padding(.bottom, SymairaSpacing.small)

            // Eleven rows do not fit a minimum-height window; the list scrolls, the rest stays.
            ScrollView(.vertical) {
                VStack(spacing: SymairaSpacing.xSmall) {
                    ForEach(CockpitDestination.allCases) { destination in
                        SymairaNavigationButton(
                            destination.title, icon: destination.icon,
                            isSelected: navigation.selection == destination, showsLabel: showsLabels
                        ) { navigation.selection = destination }
                        .accessibilityIdentifier("cockpit-destination-\(destination.rawValue)")
                    }
                }
            }
            .scrollIndicators(.never)

            Divider().overlay(SymairaTokens.line)
            agentStatus
            if showsLabels {
                Text("Symaira Cockpit · v\(version)")
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink3)
                    .padding(.leading, SymairaSpacing.small)
            }
        }
        .padding(SymairaSpacing.medium)
    }

    /// The one status line of the sidebar (SHELL-6): is the agent behind the pages there?
    @ViewBuilder
    private var agentStatus: some View {
        let (text, tone) = Self.status(agent.phase)
        Group {
            if showsLabels {
                SymairaStatusLabel(text, tone: tone)
                    .padding(.leading, SymairaSpacing.small)
            } else {
                SymairaStatusDot(tone: tone, accessibilityLabel: text)
            }
        }
        .accessibilityIdentifier("cockpit-agent-status")
    }

    static func status(_ phase: CockpitAgentStatus.Phase) -> (String, SymairaTone) {
        switch phase {
        case .starting: ("Agent starting…", .neutral)
        case .ready: ("Agent connected", .positive)
        case .failed: ("Agent not reachable", .critical)
        }
    }
}

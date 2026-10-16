import SwiftUI
import SymairaTheme

/// In-page destinations, not separate modules or copies of the tuning panel.
public enum TuneWorkspaceAnchor: String, CaseIterable, Identifiable, Sendable {
    case overview, display, power, activity, readout

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .display: "Display"
        case .power: "Power & cooling"
        case .activity: "Activity"
        case .readout: "Menu bar & HUD"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .display: "display"
        case .power: "bolt"
        case .activity: "chart.xyaxis.line"
        case .readout: "menubar.rectangle"
        }
    }
}

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

/// Native workspace chrome shared by the live window and the isolated preview.
/// Navigation scrolls one mounted panel, preserving drafts and drag state.
public struct CockpitWorkspaceView<Content: View>: View {
    let version: String
    let openPreferences: () -> Void
    let content: Content
    @Bindable private var appearance: CockpitAppearancePreferences

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarLayout = SymairaSidebarState()
    @State private var selectedAnchor = TuneWorkspaceAnchor.overview
    @State private var topography = SymairaTopoModel()
    @FocusState private var focusedAnchor: TuneWorkspaceAnchor?

    public init(
        version: String,
        openPreferences: @escaping () -> Void,
        appearance: CockpitAppearancePreferences = CockpitAppearancePreferences(),
        @ViewBuilder content: () -> Content
    ) {
        self.version = version
        self.openPreferences = openPreferences
        self.appearance = appearance
        self.content = content()
    }

    private var showsLabels: Bool { sidebarLayout.showsLabels }

    public var body: some View {
        ScrollViewReader { scroll in
            SymairaWorkspace(
                sidebar: $sidebarLayout, topography: topography,
                navigation: { _ in sidebar(scroll) },
                content: {
                    ScrollView {
                        content
                            .environment(\.tunePanelChrome, .embedded)
                            .padding(SymairaSpacing.xLarge)
                            .frame(maxWidth: 960, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                })
        }
        // The sidebar toggle lives in the window toolbar, like System
        // Settings — a dedicated header row under the title bar only
        // duplicated the title and the sidebar's own navigation.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SymairaSidebarToggle(sidebar: $sidebarLayout)
            }
            ToolbarItem(placement: .primaryAction) {
                SymairaSettingsMenu(selection: $appearance.selection, openSettings: openPreferences)
                    .accessibilityIdentifier("cockpit-settings-menu")
            }
        }
        .tint(SymairaTokens.selected)
        .onAppear(perform: appearance.apply)
    }

    private func sidebar(_ scroll: ScrollViewProxy) -> some View {
        VStack(alignment: showsLabels ? .leading : .center, spacing: SymairaSpacing.large) {
            HStack(spacing: SymairaSpacing.small) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 20, weight: .semibold))
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

            if showsLabels {
                Text("JUMP TO")
                    .symairaText(.sectionLabel, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink3)
                    .padding(.leading, SymairaSpacing.small)
            }

            VStack(spacing: SymairaSpacing.xSmall) {
                ForEach(TuneWorkspaceAnchor.allCases) { anchor in
                    Button { jump(to: anchor, in: scroll) } label: {
                        HStack(spacing: SymairaSpacing.medium) {
                            Image(systemName: anchor.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            if showsLabels {
                                Text(anchor.title)
                                    .symairaText(selectedAnchor == anchor ? .subheading : .body, respectsForeground: false)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, SymairaSpacing.medium)
                        .contentShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    }
                    .buttonStyle(SymairaNavigationButtonStyle(isSelected: selectedAnchor == anchor))
                    .focused($focusedAnchor, equals: anchor)
                    .overlay {
                        if focusedAnchor == anchor {
                            RoundedRectangle(cornerRadius: SymairaRadius.control)
                                .stroke(SymairaTokens.focus, lineWidth: 2)
                                .padding(-2)
                        }
                    }
                    .accessibilityAddTraits(selectedAnchor == anchor ? [.isSelected] : [])
                    .accessibilityLabel("Jump to \(anchor.title)")
                    .accessibilityIdentifier("cockpit-jump-\(anchor.rawValue)")
                    .help("Jump to \(anchor.title)")
                }
            }

            Spacer(minLength: SymairaSpacing.large)

            Divider().overlay(SymairaTokens.line)
            if showsLabels {
                Text("Symaira Cockpit · v\(version)")
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink3)
                    .padding(.leading, SymairaSpacing.small)
            }
        }
        .padding(SymairaSpacing.medium)
    }

    private func jump(to anchor: TuneWorkspaceAnchor, in scroll: ScrollViewProxy) {
        selectedAnchor = anchor
        if reduceMotion {
            scroll.scrollTo(anchor, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                scroll.scrollTo(anchor, anchor: .top)
            }
        }
    }
}

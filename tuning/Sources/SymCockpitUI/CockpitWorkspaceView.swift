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

    /// Named coordinate space of the workspace scroll view; anchored sections
    /// report their top edge in it so the sidebar can follow scrolling.
    static let scrollSpace = "cockpit-workspace-scroll"

    /// The section the reader is in: the last one, in page order, whose top
    /// edge has passed `threshold` (points below the viewport top). At the
    /// bottom of the page the last section wins, because short trailing
    /// sections can never reach the top. Nil when nothing was measured yet.
    public static func current(
        sectionTops: [TuneWorkspaceAnchor: CGFloat],
        threshold: CGFloat,
        atBottom: Bool
    ) -> TuneWorkspaceAnchor? {
        let measured = allCases.filter { sectionTops[$0] != nil }
        if atBottom, let last = measured.last { return last }
        return measured.last { sectionTops[$0]! <= threshold } ?? measured.first
    }
}

/// Collects each anchored section's top edge in ``TuneWorkspaceAnchor/scrollSpace``.
struct WorkspaceSectionTopsKey: PreferenceKey {
    static let defaultValue: [TuneWorkspaceAnchor: CGFloat] = [:]
    static func reduce(value: inout [TuneWorkspaceAnchor: CGFloat], nextValue: () -> [TuneWorkspaceAnchor: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this section's position so the workspace sidebar can select it
    /// while scrolling. A no-op outside the workspace scroll view.
    func workspaceSection(_ anchor: TuneWorkspaceAnchor) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WorkspaceSectionTopsKey.self,
                    value: [anchor: geometry.frame(in: .named(TuneWorkspaceAnchor.scrollSpace)).minY]
                )
            }
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
    @State private var sectionTops: [TuneWorkspaceAnchor: CGFloat] = [:]
    @State private var viewport = ScrollViewport()
    /// A sidebar click scrolls programmatically; until that scroll has
    /// settled the clicked entry stays selected instead of flickering through
    /// the sections it passes.
    @State private var followScrollAfter = Date.distantPast
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
                    .coordinateSpace(name: TuneWorkspaceAnchor.scrollSpace)
                    .onScrollGeometryChange(for: ScrollViewport.self) { geometry in
                        ScrollViewport(
                            height: geometry.containerSize.height,
                            atBottom: geometry.contentOffset.y + geometry.containerSize.height
                                >= geometry.contentSize.height - 2
                                && geometry.contentSize.height > geometry.containerSize.height
                        )
                    } action: { _, new in
                        viewport = new
                        followScroll()
                    }
                    .onPreferenceChange(WorkspaceSectionTopsKey.self) { tops in
                        sectionTops = tops
                        followScroll()
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
                            SymairaIconView(symbol: anchor.symbol, size: 20)
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

    /// Selects the section currently in view, unless a sidebar jump is still
    /// scrolling.
    private func followScroll() {
        guard Date() >= followScrollAfter,
              let current = TuneWorkspaceAnchor.current(
                  sectionTops: sectionTops,
                  threshold: max(80, viewport.height * 0.3),
                  atBottom: viewport.atBottom
              ),
              current != selectedAnchor
        else { return }
        selectedAnchor = current
    }

    private func jump(to anchor: TuneWorkspaceAnchor, in scroll: ScrollViewProxy) {
        selectedAnchor = anchor
        followScrollAfter = Date().addingTimeInterval(0.5)
        if reduceMotion {
            scroll.scrollTo(anchor, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                scroll.scrollTo(anchor, anchor: .top)
            }
        }
    }
}

/// The scroll view's visible height and whether it rests at the bottom.
private struct ScrollViewport: Equatable {
    var height: CGFloat = 0
    var atBottom = false
}

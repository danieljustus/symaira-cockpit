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

/// Native workspace chrome shared by the live window and the isolated preview.
/// Navigation scrolls one mounted panel, preserving drafts and drag state.
public struct CockpitWorkspaceView<Content: View>: View {
    let version: String
    let openPreferences: () -> Void
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarExpanded = true
    @State private var hasSidebarRoom = true

    public init(
        version: String,
        openPreferences: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.version = version
        self.openPreferences = openPreferences
        self.content = content()
    }

    private var showsLabels: Bool { sidebarExpanded && hasSidebarRoom }

    public var body: some View {
        ScrollViewReader { scroll in
            HStack(spacing: 0) {
                sidebar(scroll)
                Divider().overlay(SymairaTheme.borderGlass)
                VStack(spacing: 0) {
                    workspaceHeader(scroll)
                    Divider().overlay(SymairaTheme.borderGlass)
                    ScrollView {
                        content
                            .environment(\.tunePanelChrome, .embedded)
                            .padding(SymairaSpacing.xLarge)
                            .frame(maxWidth: 840, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .onGeometryChange(for: Bool.self) { geometry in
                geometry.size.width >= 840
            } action: { hasSidebarRoom = $0 }
        }
        .background(SymairaTheme.bgDark)
        .preferredColorScheme(.dark)
        .tint(SymairaTheme.goldPrimary)
    }

    private func sidebar(_ scroll: ScrollViewProxy) -> some View {
        VStack(alignment: showsLabels ? .leading : .center, spacing: SymairaSpacing.large) {
            HStack(spacing: SymairaSpacing.small) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(SymairaTheme.goldPrimary)
                    .frame(width: 32, height: 36)
                    .accessibilityHidden(true)
                if showsLabels {
                    Text("Cockpit")
                        .symairaText(.heading, respectsForeground: false)
                        .foregroundStyle(SymairaTheme.textPrimary)
                }
            }
            .padding(.bottom, SymairaSpacing.small)

            if showsLabels {
                Text("JUMP TO")
                    .symairaText(.sectionLabel, respectsForeground: false)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .padding(.leading, SymairaSpacing.small)
            }

            VStack(spacing: SymairaSpacing.xSmall) {
                ForEach(TuneWorkspaceAnchor.allCases) { anchor in
                    Button { jump(to: anchor, in: scroll) } label: {
                        HStack(spacing: SymairaSpacing.medium) {
                            Image(systemName: anchor.symbol)
                                .font(.system(size: 16))
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            if showsLabels {
                                Text(anchor.title)
                                    .symairaText(.body, respectsForeground: false)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(minHeight: 38)
                        .padding(.horizontal, SymairaSpacing.small)
                        .contentShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
                    }
                    .buttonStyle(WorkspaceNavigationStyle())
                    .accessibilityLabel("Jump to \(anchor.title)")
                    .accessibilityIdentifier("cockpit-jump-\(anchor.rawValue)")
                    .help("Jump to \(anchor.title)")
                }
            }

            Spacer(minLength: SymairaSpacing.large)

            Divider().overlay(SymairaTheme.borderGlass)
            Button(action: openPreferences) {
                HStack(spacing: SymairaSpacing.medium) {
                    Image(systemName: "gearshape").frame(width: 24)
                    if showsLabels {
                        Text("Preferences")
                            .symairaText(.body, respectsForeground: false)
                        Spacer(minLength: 0)
                        Text("⌘,").font(.system(size: 11))
                            .foregroundStyle(SymairaTheme.textMuted)
                    }
                }
                .frame(minHeight: SymairaMetrics.minimumControlHeight)
                .padding(.horizontal, SymairaSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceNavigationStyle())
            .accessibilityLabel("Open preferences")
            .help("Open preferences (⌘,)")

            if showsLabels {
                Text("Symaira Cockpit · v\(version)")
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .padding(.leading, SymairaSpacing.small)
            }
        }
        .padding(SymairaSpacing.medium)
        .frame(width: showsLabels ? 212 : 64)
        .background(SymairaTheme.bgCard)
    }

    private func workspaceHeader(_ scroll: ScrollViewProxy) -> some View {
        HStack(spacing: SymairaSpacing.medium) {
            Button { sidebarExpanded.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 32, height: SymairaMetrics.minimumControlHeight)
            }
            .buttonStyle(.plain)
            .disabled(!hasSidebarRoom)
            .accessibilityLabel(showsLabels ? "Collapse sidebar" : "Expand sidebar")
            .help(hasSidebarRoom ? "Toggle sidebar (⌃⌘S)" : "Sidebar is compact at this window width")
            .keyboardShortcut("s", modifiers: [.control, .command])

            Text("This Mac")
                .symairaText(.subheading, respectsForeground: false)
                .foregroundStyle(SymairaTheme.textPrimary)
            Spacer()
            Menu {
                ForEach(TuneWorkspaceAnchor.allCases) { anchor in
                    Button(anchor.title, systemImage: anchor.symbol) {
                        jump(to: anchor, in: scroll)
                    }
                }
            } label: {
                Label("Jump to", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Jump to tuning controls")
        }
        .foregroundStyle(SymairaTheme.textSecondary)
        .padding(.horizontal, SymairaSpacing.large)
        .padding(.vertical, SymairaSpacing.small)
    }

    private func jump(to anchor: TuneWorkspaceAnchor, in scroll: ScrollViewProxy) {
        if reduceMotion {
            scroll.scrollTo(anchor, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                scroll.scrollTo(anchor, anchor: .top)
            }
        }
    }
}

private struct WorkspaceNavigationStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceNavigationLabel(configuration: configuration)
    }
}

private struct WorkspaceNavigationLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? SymairaTheme.goldPrimary : SymairaTheme.textSecondary)
            .background(hovered || configuration.isPressed ? SymairaTheme.bgCardHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SymairaRadius.control))
            .onHover { hovered = $0 }
    }
}

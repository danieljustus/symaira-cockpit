import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Geometry shared by the window's pages.
enum CockpitLayout {
    /// Dashboards use a wider column than prose (LAYOUT-2).
    static let pageWidth: CGFloat = 960
    /// Width from which two cards sit side by side.
    static let columnsFrom: CGFloat = 760
}

/// Cards in one row when the page is wide, stacked when it is not. `AnyLayout` keeps
/// each card's state (a duration, a drag) when the window crosses the threshold;
/// switching between two view trees would reset it.
struct PairedCards<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isWide = false

    var body: some View {
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: SymairaSpacing.large))
            : AnyLayout(VStackLayout(spacing: SymairaSpacing.medium))
        layout { content }
            .onGeometryChange(for: Bool.self) { $0.size.width >= CockpitLayout.columnsFrom } action: { isWide = $0 }
    }
}

/// What the live pages need from the app. Built once by the status bar controller,
/// which owns the models the popover shares; pages take what they use from here and
/// never construct a controller or touch hardware.
@MainActor
struct CockpitPageContext {
    let session: AgentSession
    let model: TuneViewModel
    let config: TuneConfig
    let aiUsageModel: AIUsageViewModel
    let preferencesManager: PreferencesManager
    let profiles: ProfilesModel
    let history: HistoryModel
    let openPreferences: () -> Void
    var brightnessKeyPreferences: BrightnessKeyPreferences?
    var brightnessKeyController: BrightnessKeyController?
    var readoutPreferences: ReadoutSurfacePreferences?
    var hudDockPreferences: HUDDockPreferences?
    var hudItemPreferences: HUDItemPreferences?
}

/// The page for a destination. The six areas whose pages are still placeholders get
/// only the agent session.
@MainActor
struct CockpitPageHost: View {
    let context: CockpitPageContext
    let destination: CockpitDestination

    var body: some View {
        switch destination {
        case .overview: OverviewPage(context: context)
        case .display: DisplayPage(context: context)
        case .powerFans: PowerFansPage(context: context)
        case .storage: StoragePage(session: context.session)
        case .audioMIDI: AudioMIDIPage(session: context.session)
        case .bluetoothInput: BluetoothInputPage(session: context.session)
        case .processes: ProcessesPage(session: context.session)
        case .clipboard: ClipboardPage(session: context.session)
        case .finder: FinderPage(session: context.session)
        case .aiUsage: AIUsagePage(context: context)
        case .history: HistoryPage(model: context.history)
        }
    }
}

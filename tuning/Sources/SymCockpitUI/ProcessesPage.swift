import SwiftUI
import SymCockpitCore
import SymairaTheme

// Screen card
// 1. Destination: Processes in the workspace sidebar.
// 2. Job: find a busy process and review a plan to end it.
// 3. Data: the shared agent process rankings while visible, with a fresh plan on demand.
// 4. States: sampling, no readable processes, unavailable GPU or termination, agent errors;
//    the workspace shows the agent diagnosis when disconnected.
// 5. Density: compact ranked list with details for the selected row.
// 6. Platform: macOS workspace, with no preference keys.

@MainActor
public struct ProcessesPage: View {
    private let session: AgentSession
    private let isWindowVisible: Bool
    @State private var processes: ProcessesViewModel
    @State private var termination: ProcessKillModel

    public init(session: AgentSession, isWindowVisible: Bool = true) {
        self.session = session
        self.isWindowVisible = isWindowVisible
        let processes = ProcessesViewModel(session: session, owner: "workspace-processes")
        _processes = State(initialValue: processes)
        _termination = State(initialValue: ProcessKillModel(session: session, didFinish: { [weak processes] in
            processes?.refreshNow()
        }))
    }

    public var body: some View {
        SymairaPage(
            title: CockpitDestination.processes.title, subtitle: CockpitDestination.processes.subtitle,
            maxWidth: CockpitLayout.pageWidth
        ) {
            if session.hello?.topics.contains("processes") == false {
                PageCard(title: "Top Processes", icon: .cpu) {
                    SymairaNotice(message: "This agent does not offer process sampling.", tone: .warning)
                }
            } else {
                PageCard(title: "Top Processes", icon: .cpu, identifier: "workspace-processes") {
                    ProcessList(model: processes, termination: termination)
                }
                .onChange(of: isWindowVisible, initial: true) { _, visible in
                    processes.setVisible(visible)
                }
                .onDisappear { processes.setVisible(false) }
            }
        }
    }
}

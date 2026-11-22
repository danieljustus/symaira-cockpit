import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The places of the cockpit window, in sidebar order. Names are the page titles;
/// the window shows one page at a time and never a second copy of the popover.
public enum CockpitDestination: String, CaseIterable, Identifiable, Sendable {
    case overview, display, powerFans, storage, audioMIDI, bluetoothInput
    case processes, clipboard, finder, aiUsage, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .display: "Display"
        case .powerFans: "Power & Fans"
        case .storage: "Storage"
        case .audioMIDI: "Audio & MIDI"
        case .bluetoothInput: "Bluetooth & Input"
        case .processes: "Processes"
        case .clipboard: "Clipboard"
        case .finder: "Finder"
        case .aiUsage: "AI Usage"
        case .history: "History"
        }
    }

    /// The one line under the page title.
    public var subtitle: String {
        switch self {
        case .overview: "How this Mac is doing right now"
        case .display: "Brightness, warmth, wake lock and saved profiles"
        case .powerFans: "Fan profile, battery and charge limit"
        case .storage: "Volumes, space and cleanup"
        case .audioMIDI: "Audio devices, per-app volume and MIDI"
        case .bluetoothInput: "Bluetooth devices, keyboards and pointers"
        case .processes: "What is running and what it costs"
        case .clipboard: "Clipboard history, kept on this Mac"
        case .finder: "Finder actions and cut and paste"
        case .aiUsage: "Usage and limits of your AI providers"
        case .history: "What Cockpit changed on this Mac"
        }
    }

    var icon: SymairaIcon {
        switch self {
        case .overview: .dashboard
        case .display: .lightMode
        case .powerFans: .fan
        case .storage: .storage
        case .audioMIDI: .audio
        case .bluetoothInput: .keyboard
        case .processes: .cpu
        case .clipboard: .paste
        case .finder: .folder
        case .aiUsage: .ai
        case .history: .history
        }
    }

    /// ⌘1 to ⌘9 for the first nine destinations; the rest are reached from the sidebar.
    public var shortcutDigit: Character? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return Character(String(index + 1))
    }
}

// MARK: - Agent status

/// The agent as the window needs it: a sidebar status line, and the state every
/// page waits for before it shows anything (STATE-4: no zeros while it is down).
@MainActor
@Observable
public final class CockpitAgentStatus {
    public enum Phase: Equatable, Sendable {
        case starting
        case ready(version: String)
        case failed(AgentDiagnosis)
    }

    public private(set) var phase: Phase
    @ObservationIgnored private let session: AgentSession?

    public init(session: AgentSession) {
        self.session = session
        self.phase = Self.phase(for: session.state)
        session.addStateObserver { [weak self] state in
            Task { @MainActor in self?.phase = Self.phase(for: state) }
        }
    }

    /// A fixed phase for previews and tests that have no agent.
    public init(fixed phase: Phase) {
        self.session = nil
        self.phase = phase
    }

    public func restart() {
        guard let session else { return }
        Task { await session.restart() }
    }

    nonisolated static func phase(for state: AgentState) -> Phase {
        switch state {
        case .stopped, .starting: .starting
        case .ready(let hello): .ready(version: hello.serverVersion)
        case .failed:
            .failed(AgentDiagnosis.of(state) ?? AgentDiagnosis(title: "Cockpit agent stopped", detail: "The agent is not running."))
        }
    }
}

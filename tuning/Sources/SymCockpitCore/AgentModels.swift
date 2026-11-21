import Foundation

// Shapes of agent answers that no other Core type already has.

/// `fan status`: the stored selection and whether a governor enforces it.
public struct FanStatus: Codable, Sendable, Equatable {
    public let profile: FanProfile
    public let governorRunning: Bool
    public let coolTargetCelsius: Double?
    /// Mean CPU/GPU cluster temperature, rounded to 0.1 °C by the agent.
    public let averageClusterCelsius: Double?
}

/// What the UI shows while the agent cannot serve: a headline and the reason,
/// in the agent client's own words. `nil` when the agent is fine or not asked yet.
public struct AgentDiagnosis: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    public static func of(_ state: AgentState) -> AgentDiagnosis? {
        guard case .failed(let failure) = state else { return nil }
        return AgentDiagnosis(title: failure.diagnosisTitle, detail: failure.localizedDescription)
    }
}

extension AgentFailure {
    var diagnosisTitle: String {
        switch self {
        case .executableMissing: return "Cockpit agent missing"
        case .launchFailed: return "Cockpit agent did not start"
        case .versionMismatch: return "Cockpit agent has another version"
        case .protocolViolation: return "Cockpit agent sent something unexpected"
        case .exited(let status, _): return status == 3 ? "Cockpit agent refused to start" : "Cockpit agent stopped"
        case .timedOut: return "Cockpit agent does not answer"
        case .notRunning: return "Cockpit agent is not running"
        }
    }
}

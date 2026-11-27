import Foundation

// Shapes of agent answers that no other Core type already has.

/// `fan status`: the stored selection, whether a governor enforces it and the
/// raw SMC fan state (so a stale manual override is visible even on `system`).
public struct FanStatus: Codable, Sendable, Equatable {
    /// One fan's raw mode and target RPM as the agent read them.
    public struct FanState: Codable, Sendable, Equatable {
        public let mode: UInt8?
        public let targetRpm: Double?

        public init(mode: UInt8?, targetRpm: Double?) {
            self.mode = mode
            self.targetRpm = targetRpm
        }
    }

    public let profile: FanProfile
    public let governorRunning: Bool
    public let coolTargetCelsius: Double?
    /// Mean CPU/GPU cluster temperature, rounded to 0.1 °C by the agent.
    public let averageClusterCelsius: Double?
    public let softwareOverride: Bool
    public let fans: [FanState]

    public init(
        profile: FanProfile,
        governorRunning: Bool,
        coolTargetCelsius: Double?,
        averageClusterCelsius: Double?,
        softwareOverride: Bool = false,
        fans: [FanState] = []
    ) {
        self.profile = profile
        self.governorRunning = governorRunning
        self.coolTargetCelsius = coolTargetCelsius
        self.averageClusterCelsius = averageClusterCelsius
        self.softwareOverride = softwareOverride
        self.fans = fans
    }
}

extension FanStatus {
    /// Older agents sent only the four original keys; missing additive fields
    /// mean "nothing readable", never a fabricated override.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(FanProfile.self, forKey: .profile)
        governorRunning = try values.decode(Bool.self, forKey: .governorRunning)
        coolTargetCelsius = try values.decodeIfPresent(Double.self, forKey: .coolTargetCelsius)
        averageClusterCelsius = try values.decodeIfPresent(Double.self, forKey: .averageClusterCelsius)
        softwareOverride = try values.decodeIfPresent(Bool.self, forKey: .softwareOverride) ?? false
        fans = try values.decodeIfPresent([FanState].self, forKey: .fans) ?? []
    }
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

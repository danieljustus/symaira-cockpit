import Foundation

/// Which side of the connection is deciding.
public enum FanHelperPeerRole: Sendable, Equatable {
    /// The helper deciding whether to accept its client.
    case helperAcceptingApp
    /// The app deciding whether to accept the helper.
    case appAcceptingHelper
}

/// Checks the *current process* against a requirement string.
public protocol CodeRequirementValidating: Sendable {
    func satisfies(requirement: String) -> Bool
}

/// The slice of `NSXPCConnection` / `NSXPCListener` the policy needs.
public protocol XPCRequirementApplying {
    func applyCodeSigningRequirement(_ requirement: String)
}

extension NSXPCConnection: XPCRequirementApplying {
    public func applyCodeSigningRequirement(_ requirement: String) {
        setCodeSigningRequirement(requirement)
    }
}

public enum FanHelperConnectionDecision: Sendable, Equatable {
    case accept(requirement: String)
    case reject(reason: String)
}

/// Decides whether this process may take part in a helper connection at all,
/// and with which peer requirement. Fails closed: a missing or malformed team
/// identifier, or an own signature that does not itself satisfy the pinned
/// Developer ID requirement (an ad-hoc or self-signed build claiming a team),
/// rejects every connection.
public enum FanHelperConnectionPolicy {
    public static func decide(
        role: FanHelperPeerRole,
        ownTeamID: String?,
        selfValidator: any CodeRequirementValidating
    ) -> FanHelperConnectionDecision {
        guard let ownTeamID else {
            return .reject(reason: "this binary carries no team identifier (unsigned or ad-hoc)")
        }
        guard CodeSigningRequirements.isValidTeamIdentifier(ownTeamID) else {
            return .reject(reason: "malformed team identifier")
        }

        let peerRequirement: String?
        let ownRequirement: String?
        switch role {
        case .helperAcceptingApp:
            peerRequirement = CodeSigningRequirements.appRequirement(teamID: ownTeamID)
            ownRequirement = CodeSigningRequirements.helperRequirement(teamID: ownTeamID)
        case .appAcceptingHelper:
            peerRequirement = CodeSigningRequirements.helperRequirement(teamID: ownTeamID)
            ownRequirement = CodeSigningRequirements.appRequirement(teamID: ownTeamID)
        }
        guard let peerRequirement, let ownRequirement else {
            return .reject(reason: "could not construct a code-signing requirement")
        }
        guard selfValidator.satisfies(requirement: ownRequirement) else {
            return .reject(reason: "own signature does not satisfy the Developer ID requirement")
        }
        return .accept(requirement: peerRequirement)
    }

    /// Applies the decision to `connection`. Returns false — and applies
    /// nothing — when the connection must be refused. A connection that was
    /// accepted still gets its requirement enforced by the system on every
    /// message, from the peer's audit token.
    @discardableResult
    public static func secure(
        _ connection: some XPCRequirementApplying,
        role: FanHelperPeerRole,
        ownTeamID: String?,
        selfValidator: any CodeRequirementValidating
    ) -> Bool {
        switch decide(role: role, ownTeamID: ownTeamID, selfValidator: selfValidator) {
        case .accept(let requirement):
            connection.applyCodeSigningRequirement(requirement)
            return true
        case .reject:
            return false
        }
    }
}

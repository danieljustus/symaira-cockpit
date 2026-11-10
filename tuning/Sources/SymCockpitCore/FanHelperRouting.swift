import Foundation

/// How the optional privileged fan helper (issue #405) relates to this
/// process, as far as the *routing* of a fan change is concerned.
///
/// The helper is opt-in and off by default. Everything that decides between
/// it and the existing `osascript` elevation lives in ``FanHelperRouting``,
/// a pure function, so "unsigned builds never touch the helper" and "off means
/// the old path, unchanged" are checkable without a daemon.

/// The code-signing state of the running app.
public enum FanHelperSigning: Sendable, Equatable {
    /// Developer-ID signed (chains to Apple, carries a team identifier).
    case releaseSigned(teamID: String)
    /// Unsigned, ad-hoc or self-signed: local and CI builds, `swift run`.
    case unsigned
}

/// The `SMAppService` registration state of the helper daemon.
public enum FanHelperRegistration: Sendable, Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user has not approved it in System Settings yet.
    case requiresApproval
    /// The daemon plist is not part of this bundle.
    case notFound
}

/// What the app can honestly say about the helper right now.
public enum FanHelperAvailability: Sendable, Equatable {
    /// This build cannot use the helper at all.
    case unavailable(Reason)
    /// Available but not opted into (the default).
    case off
    /// Opted in, not registered (yet).
    case notRegistered
    /// Registered; waiting for approval under System Settings → General →
    /// Login Items & Extensions.
    case requiresApproval
    /// Opted in, registered and approved.
    case enabled

    public enum Reason: Sendable, Equatable {
        /// Not Developer-ID signed.
        case unsigned
        /// The helper is not embedded in this bundle.
        case notBundled
    }
}

/// Where a fan change is sent.
public enum FanHelperRoute: Sendable, Equatable {
    /// The existing path: `osascript … with administrator privileges` on a
    /// root-owned `symcockpit`.
    case osascript
    /// The registered, approved helper — no administrator prompt.
    case helper
}

public enum FanHelperRouting {
    public static func availability(
        optedIn: Bool,
        signing: FanHelperSigning,
        registration: FanHelperRegistration
    ) -> FanHelperAvailability {
        guard case .releaseSigned = signing else { return .unavailable(.unsigned) }
        if registration == .notFound { return .unavailable(.notBundled) }
        guard optedIn else { return .off }
        switch registration {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        }
    }

    /// The helper only when it is fully enabled. A pending approval, an
    /// unsigned build or a missing opt-in all keep the `osascript` path, so a
    /// half-set-up helper never makes fan control stop working.
    public static func route(for availability: FanHelperAvailability) -> FanHelperRoute {
        availability == .enabled ? .helper : .osascript
    }
}

/// The persisted opt-in. Lives in the grandfathered `com.symaira.symtune`
/// namespace (never rename it) and defaults to off.
public enum FanHelperDefaults {
    public static let enabledKey = "com.symaira.symtune.fanHelper.enabled"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}

/// What ``TuneController`` needs from a fan helper. The concrete client (XPC,
/// `SMAppService`) lives in `SymCockpitHelperKit`; the CLI and MCP server never
/// receive one, so only the GUI can ever take this path.
public protocol FanHelperControlling: Sendable {
    func availability() -> FanHelperAvailability
    /// Start the helper's governor on `profile`, or retarget a running one.
    func startGovernor(profile: FanProfile) throws
    /// Hand the fans back to the firmware and stop heartbeating.
    func stopGovernor() throws
}

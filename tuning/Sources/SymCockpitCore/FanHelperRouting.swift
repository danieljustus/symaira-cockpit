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

    /// What the GUI does when the user selects `profile` and fan changes may
    /// lack the rights to take effect.
    ///
    /// Only a release-signed build with the helper bundled can offer a better
    /// way than the administrator prompt, so only there is a missing right a
    /// reason to take the user somewhere:
    ///
    /// - Standard (`.system`) never navigates: it needs no rights at all.
    /// - A governor that already runs follows the change by itself (the
    ///   legacy one re-reads the stored selection, the helper one is
    ///   retargeted), so nothing is missing.
    /// - Helper off or opted in but not registered: Preferences, at the
    ///   "Privileged fan helper" section.
    /// - Registered but awaiting approval: System Settings → Login Items.
    /// - Enabled, unsigned/unbundled builds, and no helper at all (CLI/MCP,
    ///   `availability == nil`) keep the unchanged routes.
    public static func selectionAction(
        for profile: FanProfile,
        availability: FanHelperAvailability?,
        governorRunning: Bool
    ) -> FanSelectionAction {
        guard let availability else { return .proceed(.osascript) }
        let route = route(for: availability)
        guard profile != .system, !governorRunning else { return .proceed(route) }
        switch availability {
        case .off, .notRegistered: return .openHelperPreferences
        case .requiresApproval: return .openSystemSettingsApproval
        case .enabled, .unavailable: return .proceed(route)
        }
    }
}

/// The outcome of ``FanHelperRouting/selectionAction(for:availability:governorRunning:)``.
public enum FanSelectionAction: Sendable, Equatable {
    /// Apply the change through `route`, as before.
    case proceed(FanHelperRoute)
    /// Do not change anything; show Preferences at the helper section.
    case openHelperPreferences
    /// Do not change anything; open System Settings → Login Items so the user
    /// can approve the registered helper.
    case openSystemSettingsApproval

    /// The one-line explanation shown where the user lands.
    public var hint: String? {
        switch self {
        case .proceed:
            return nil
        case .openHelperPreferences:
            return "Turn on the privileged fan helper to change fan speed without an administrator password."
        case .openSystemSettingsApproval:
            return "Approve the Symaira Cockpit helper in System Settings → Login Items to change fan speed."
        }
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

/// What the app knows about the helper's governor right now. Cached from the
/// last reply, so reading it never blocks on XPC.
public struct FanHelperGovernorStatus: Sendable, Equatable {
    public var isGoverning: Bool
    /// The profile the helper is governing, when it is.
    public var profile: FanProfile?
    /// The Cool target the helper is governing with, when it has one.
    public var coolTarget: Double?
    /// Set when the app lost contact with a governing helper (a failed
    /// retarget, a dropped connection). The helper keeps governing until its
    /// heartbeat watchdog fires, so until this instant it must still count as
    /// governing: nothing else may write the SMC beside it.
    public var mayStillGovernUntil: Date?

    public init(
        isGoverning: Bool,
        profile: FanProfile? = nil,
        coolTarget: Double? = nil,
        mayStillGovernUntil: Date? = nil
    ) {
        self.isGoverning = isGoverning
        self.profile = profile
        self.coolTarget = coolTarget
        self.mayStillGovernUntil = mayStillGovernUntil
    }

    /// Governing for sure, or possibly still governing at `date`.
    public func isGoverningOrMayBe(at date: Date = Date()) -> Bool {
        if isGoverning { return true }
        guard let until = mayStillGovernUntil else { return false }
        return date < until
    }

    public static let idle = FanHelperGovernorStatus(isGoverning: false)
}

/// What ``TuneController`` needs from a fan helper. The concrete client (XPC,
/// `SMAppService`) lives in `SymCockpitHelperKit`; the CLI and MCP server never
/// receive one, so only the GUI can ever take this path.
public protocol FanHelperControlling: Sendable {
    func availability() -> FanHelperAvailability
    /// Start the helper's governor on `profile`, or retarget a running one.
    ///
    /// Success means the helper accepted the request, not that the first
    /// governor tick succeeded: the governor reports an immediate failure
    /// (SMC unavailable, no thermal headroom) through the helper's `status`
    /// and, via the next heartbeat, through ``governorStatus()``.
    ///
    /// `coolTarget` is the optional Cool-position maximum average temperature
    /// (``FanCoolTarget``); nil means none. The helper validates it again.
    func startGovernor(profile: FanProfile, coolTarget: Double?) throws
    /// Hand the fans back to the firmware and stop heartbeating.
    func stopGovernor() throws
    /// Whether the helper is governing the fans, from the last reply. Used so
    /// the UI/HUD do not claim "no governor is running" while it is.
    func governorStatus() -> FanHelperGovernorStatus
    /// Opens System Settings → Login Items, where the user approves the helper.
    func openSystemSettings()
}

extension FanHelperControlling {
    /// Start or retarget without a Cool target.
    public func startGovernor(profile: FanProfile) throws {
        try startGovernor(profile: profile, coolTarget: nil)
    }
    public func governorStatus() -> FanHelperGovernorStatus { .idle }
    /// Hosts that cannot open System Settings do nothing.
    public func openSystemSettings() {}
}

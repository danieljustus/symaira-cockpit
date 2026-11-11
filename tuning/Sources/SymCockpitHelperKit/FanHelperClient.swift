import Foundation
import SymCockpitCore

/// App-side controller of the optional fan helper (issue #405).
///
/// Implements ``FanHelperControlling`` for `TuneController` and offers the
/// registration management the preferences UI needs. Creating one is free of
/// side effects: nothing is registered, no connection is opened and no
/// credential is read until the user opts in and a fan change asks for it.
public final class FanHelperClient: FanHelperControlling, @unchecked Sendable {
    private let daemon: any FanHelperDaemonService
    private let signing: @Sendable () -> FanHelperSigning
    private let optedIn: @Sendable () -> Bool
    private let makeTransport: @Sendable (_ teamID: String) throws -> any FanHelperTransport
    private let heartbeatInterval: TimeInterval
    private let bundleCheck: @Sendable () -> String?
    private let now: @Sendable () -> Date
    /// How long a helper that lost contact with the app may keep governing:
    /// its heartbeat timeout plus one watchdog check interval.
    static let watchdogWindow = FanHelperConstants.heartbeatTimeout
        + FanHelperConstants.watchdogCheckInterval

    private let lock = NSLock()
    private var transport: (any FanHelperTransport)?
    private var heartbeat: DispatchSourceTimer?
    private var status = FanHelperGovernorStatus.idle
    /// Profile of the last accepted start, re-sent when a heartbeat reports
    /// that the helper lost its governor.
    private var lastProfile: FanProfile?
    private var lastCoolTarget: Double?
    private var healAttempts = 0
    /// The helper may still be governing until this instant although the app
    /// lost contact with it (see ``FanHelperGovernorStatus/mayStillGovernUntil``).
    private var mayStillGovernUntil: Date?
    private var heartbeatObserver: (@Sendable () -> Void)?
    /// Bound for re-starting a governor the helper dropped, per user action.
    static let maxHealAttempts = 3
    private let heartbeatQueue = DispatchQueue(label: "symaira.fan-helper.heartbeat")

    public init(
        daemon: any FanHelperDaemonService = SMAppServiceDaemon(),
        signing: @escaping @Sendable () -> FanHelperSigning = { FanHelperClient.detectSigning() },
        optedIn: @escaping @Sendable () -> Bool = { FanHelperDefaults.isEnabled() },
        heartbeatInterval: TimeInterval = FanHelperConstants.heartbeatInterval,
        bundleCheck: (@Sendable () -> String?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTransport: (@Sendable (_ teamID: String) throws -> any FanHelperTransport)? = nil
    ) {
        self.bundleCheck = bundleCheck ?? {
            BundleTrustCheck.problem(
                appBundle: Bundle.main.bundleURL,
                helperExecutable: Bundle.main.bundleURL
                    .appendingPathComponent(FanHelperConstants.helperBundleProgram)
            )
        }
        self.now = now
        self.daemon = daemon
        self.signing = signing
        self.optedIn = optedIn
        self.heartbeatInterval = heartbeatInterval
        self.makeTransport = makeTransport ?? { teamID in
            try XPCFanHelperTransport(
                teamID: teamID,
                bundledHelper: Bundle.main.bundleURL
                    .appendingPathComponent(FanHelperConstants.helperBundleProgram)
            )
        }
    }

    deinit { stopHeartbeat(); lock.lock(); transport?.invalidate(); lock.unlock() }

    /// Release-signed only when the running app chains to Apple's Developer ID
    /// CA with a team identifier *and* satisfies the app requirement for that
    /// team. Local, ad-hoc and self-signed builds are `.unsigned` and never
    /// touch the helper.
    public static func detectSigning(
        embeddedTeamID: String? = EmbeddedTeamIdentifier.value
    ) -> FanHelperSigning {
        // Both the team read from this binary's signature and the one baked
        // in at build time must agree; a build without the latter never
        // registers or serves the helper.
        guard let embeddedTeamID,
              let team = CodeSignatureInspector.ownTeamIdentifier(),
              team == embeddedTeamID,
              let requirement = CodeSigningRequirements.appRequirement(teamID: team),
              SelfCodeRequirementValidator().satisfies(requirement: requirement)
        else { return .unsigned }
        return .releaseSigned(teamID: team)
    }

    // MARK: - FanHelperControlling

    public func availability() -> FanHelperAvailability {
        FanHelperRouting.availability(
            optedIn: optedIn(), signing: signing(), registration: daemon.registration
        )
    }

    public func startGovernor(profile: FanProfile, coolTarget: Double?) throws {
        guard availability() == .enabled, case .releaseSigned(let teamID) = signing() else {
            throw TuneError.permission("the privileged fan helper is not enabled")
        }
        lock.lock()
        let wasGoverning = status.isGoverning
        lock.unlock()
        do {
            // Re-checked on every start, not only at register: the bundle may
            // have been rewritten since.
            if let problem = bundleCheck() { throw TuneError.permission(problem) }
            let transport = try connectedTransport(teamID: teamID)
            try transport.startGovernor(profile: profile.rawValue, coolTarget: coolTarget)
            lock.lock()
            status = FanHelperGovernorStatus(isGoverning: true, profile: profile, coolTarget: coolTarget)
            lastProfile = profile
            lastCoolTarget = coolTarget
            healAttempts = 0
            mayStillGovernUntil = nil
            lock.unlock()
            startHeartbeat()
        } catch {
            // A failed retarget leaves the helper governing its previous
            // profile until its watchdog fires: keep reporting that.
            dropTransport(helperMayStillGovern: wasGoverning)
            if let error = error as? TuneError { throw error }
            throw TuneError.permission("\(error)")
        }
    }

    public func governorStatus() -> FanHelperGovernorStatus {
        lock.lock(); defer { lock.unlock() }
        var current = status
        if !current.isGoverning, let until = mayStillGovernUntil {
            if now() < until { current.mayStillGovernUntil = until } else { mayStillGovernUntil = nil }
        }
        return current
    }

    /// Called on the heartbeat queue after every answered heartbeat. The app
    /// uses it to reconcile the stored fan profile with the helper (a CLI or
    /// MCP `fan profile system` must still end helper-driven governing).
    public func setHeartbeatObserver(_ observer: (@Sendable () -> Void)?) {
        lock.lock()
        heartbeatObserver = observer
        lock.unlock()
    }

    public func stopGovernor() throws {
        stopHeartbeat()
        lock.lock()
        let current = transport
        let wasGoverning = status.isGoverning
        status = .idle
        lastProfile = nil
        lastCoolTarget = nil
        mayStillGovernUntil = nil
        lock.unlock()
        do {
            try current?.stopGovernor()
            dropTransport()
        } catch {
            // The stop did not reach the helper; it hands the fans back on
            // its own once the heartbeats have stopped.
            dropTransport(helperMayStillGovern: wasGoverning)
            throw error
        }
    }

    // MARK: - Registration management (preferences UI)

    /// Registers the daemon. Returns the resulting availability; when that is
    /// `.requiresApproval`, the caller should offer ``openSystemSettings()``.
    @discardableResult
    public func register() throws -> FanHelperAvailability {
        guard case .releaseSigned = signing() else {
            throw TuneError.unsupported(
                "the privileged fan helper needs a release-signed Symaira Cockpit build"
            )
        }
        // The registered helper runs as root from inside this bundle: refuse
        // while anyone but the owner could swap it (see BundleTrustCheck).
        if let problem = bundleCheck() {
            throw TuneError.permission(problem)
        }
        do { try daemon.register() } catch {
            // `register()` throws when approval is still pending; that state
            // is reported through the status, not as a failure.
            if daemon.registration != .requiresApproval { throw error }
        }
        return availability()
    }

    /// Hands the fans back, then unregisters and removes the daemon.
    public func unregister() throws {
        try? stopGovernor()
        // Nothing registered (never registered, or the bundle moved): there
        // is nothing to remove, and SMAppService would throw.
        switch daemon.registration {
        case .notRegistered, .notFound: return
        case .enabled, .requiresApproval: try daemon.unregister()
        }
    }

    public func openSystemSettings() { daemon.openSystemSettings() }

    // MARK: - Internals

    private func connectedTransport(teamID: String) throws -> any FanHelperTransport {
        lock.lock()
        defer { lock.unlock() }
        if let transport { return transport }
        let created = try makeTransport(teamID)
        transport = created
        return created
    }

    /// Closes the connection and forgets the governor. With
    /// `helperMayStillGovern` the helper is assumed to keep governing until its
    /// watchdog fires, and ``governorStatus()`` says so for that window.
    private func dropTransport(helperMayStillGovern: Bool = false) {
        stopHeartbeat()
        lock.lock()
        let old = transport
        transport = nil
        status = .idle
        mayStillGovernUntil = helperMayStillGovern ? now().addingTimeInterval(Self.watchdogWindow) : nil
        lock.unlock()
        old?.invalidate()
    }

    private func startHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: heartbeatQueue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.beat() }
        heartbeat = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        lock.lock()
        let timer = heartbeat
        heartbeat = nil
        lock.unlock()
        timer?.cancel()
    }

    private func beat() {
        lock.lock()
        let current = transport
        lock.unlock()
        guard let current else { return stopHeartbeat() }
        let stillGoverning: Bool
        do { stillGoverning = try current.heartbeat() } catch {
            // The helper restores the fans itself once the pings stop; there
            // is nothing more to do here than not pretend to still govern.
            Self.log("heartbeat failed, handing the fans back: \(error)")
            // Unreachable is not stopped: the helper governs until its
            // watchdog notices the missing pings.
            dropTransport(helperMayStillGovern: true)
            return
        }
        if !stillGoverning { healLostGovernor(via: current) }
        lock.lock()
        let observer = heartbeatObserver
        lock.unlock()
        observer?()
    }

    /// The helper answered but no longer governs (its governor gave up, or it
    /// restarted). Re-send the last profile a bounded number of times per user
    /// action; after that, stop pretending and let the UI report it.
    private func healLostGovernor(via transport: any FanHelperTransport) {
        lock.lock()
        let profile = lastProfile
        let coolTarget = lastCoolTarget
        let attempt = healAttempts
        lock.unlock()
        guard let profile, attempt < Self.maxHealAttempts else {
            Self.log("the helper's governor stopped and was not restarted")
            stopHeartbeat()
            lock.lock()
            status = .idle
            lock.unlock()
            return
        }
        if let problem = bundleCheck() {
            Self.log("not restarting the helper's governor: \(problem)")
            stopHeartbeat()
            lock.lock()
            status = .idle
            lock.unlock()
            return
        }
        lock.lock(); healAttempts += 1; lock.unlock()
        Self.log("the helper's governor stopped; restarting (\(attempt + 1)/\(Self.maxHealAttempts))")
        do { try transport.startGovernor(profile: profile.rawValue, coolTarget: coolTarget) } catch {
            Self.log("restart failed: \(error)")
            dropTransport()
        }
    }

    private static func log(_ message: String) {
        fputs("symaira fan helper client: \(message)\n", stderr)
    }
}

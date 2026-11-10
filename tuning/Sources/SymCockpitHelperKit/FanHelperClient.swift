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

    private let lock = NSLock()
    private var transport: (any FanHelperTransport)?
    private var heartbeat: DispatchSourceTimer?
    private var status = FanHelperGovernorStatus.idle
    /// Profile of the last accepted start, re-sent when a heartbeat reports
    /// that the helper lost its governor.
    private var lastProfile: FanProfile?
    private var healAttempts = 0
    private var heartbeatObserver: (@Sendable () -> Void)?
    /// Bound for re-starting a governor the helper dropped, per user action.
    static let maxHealAttempts = 3
    private let heartbeatQueue = DispatchQueue(label: "symaira.fan-helper.heartbeat")

    public init(
        daemon: any FanHelperDaemonService = SMAppServiceDaemon(),
        signing: @escaping @Sendable () -> FanHelperSigning = FanHelperClient.detectSigning,
        optedIn: @escaping @Sendable () -> Bool = { FanHelperDefaults.isEnabled() },
        heartbeatInterval: TimeInterval = FanHelperConstants.heartbeatInterval,
        makeTransport: (@Sendable (_ teamID: String) throws -> any FanHelperTransport)? = nil
    ) {
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
    public static func detectSigning() -> FanHelperSigning {
        guard let team = CodeSignatureInspector.ownTeamIdentifier(),
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

    public func startGovernor(profile: FanProfile) throws {
        guard availability() == .enabled, case .releaseSigned(let teamID) = signing() else {
            throw TuneError.permission("the privileged fan helper is not enabled")
        }
        do {
            let transport = try connectedTransport(teamID: teamID)
            try transport.startGovernor(profile: profile.rawValue)
            lock.lock()
            status = FanHelperGovernorStatus(isGoverning: true, profile: profile)
            lastProfile = profile
            healAttempts = 0
            lock.unlock()
            startHeartbeat()
        } catch {
            dropTransport()
            throw TuneError.permission("\(error)")
        }
    }

    public func governorStatus() -> FanHelperGovernorStatus {
        lock.lock(); defer { lock.unlock() }
        return status
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
        status = .idle
        lastProfile = nil
        lock.unlock()
        defer { dropTransport() }
        try current?.stopGovernor()
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
        try daemon.unregister()
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

    private func dropTransport() {
        stopHeartbeat()
        lock.lock()
        let old = transport
        transport = nil
        status = .idle
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
            dropTransport()
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
        lock.lock(); healAttempts += 1; lock.unlock()
        Self.log("the helper's governor stopped; restarting (\(attempt + 1)/\(Self.maxHealAttempts))")
        do { try transport.startGovernor(profile: profile.rawValue) } catch {
            Self.log("restart failed: \(error)")
            dropTransport()
        }
    }

    private static func log(_ message: String) {
        fputs("symaira fan helper client: \(message)\n", stderr)
    }
}

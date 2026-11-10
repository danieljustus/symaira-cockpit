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
            startHeartbeat()
        } catch {
            dropTransport()
            throw TuneError.permission("\(error)")
        }
    }

    public func stopGovernor() throws {
        stopHeartbeat()
        lock.lock()
        let current = transport
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
        lock.unlock()
        old?.invalidate()
    }

    private func startHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
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
        do { try current.heartbeat() } catch {
            // The helper restores the fans itself once the pings stop; there
            // is nothing more to do here than not pretend to still govern.
            dropTransport()
        }
    }
}

import Foundation
import ServiceManagement
import SymCockpitCore

/// The `SMAppService` side: registration of the embedded launch daemon.
public protocol FanHelperDaemonService: Sendable {
    var registration: FanHelperRegistration { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The real daemon service. Constructing it does not register anything.
public struct SMAppServiceDaemon: FanHelperDaemonService {
    private let plistIsBundled: @Sendable () -> Bool

    public init(
        plistIsBundled: @escaping @Sendable () -> Bool = {
            FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Library/LaunchDaemons")
                    .appendingPathComponent(FanHelperConstants.launchdPlistName).path
            )
        }
    ) {
        self.plistIsBundled = plistIsBundled
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: FanHelperConstants.launchdPlistName)
    }

    public var registration: FanHelperRegistration {
        Self.registration(for: service.status, plistIsBundled: plistIsBundled)
    }

    /// `SMAppService` reports `.notFound` for a daemon that was never
    /// registered, not only for a missing plist (issue #411). Treating that
    /// as "not bundled" disabled the only control that registers it, so a
    /// never-registered daemon whose plist ships in the bundle is
    /// `.notRegistered`; `.notFound` remains for a bundle without the plist.
    static func registration(
        for status: SMAppService.Status,
        plistIsBundled: () -> Bool
    ) -> FanHelperRegistration {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return plistIsBundled() ? .notRegistered : .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }

    /// Opens System Settings → General → Login Items & Extensions, where the
    /// user approves the helper.
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The XPC side, narrowed to what the client uses so the heartbeat and
/// routing logic is testable without a daemon.
public protocol FanHelperTransport: Sendable {
    func startGovernor(profile: String) throws
    /// Throws when the helper is unreachable. Returns whether the helper still
    /// has a governor running (false: it gave up or was stopped meanwhile).
    func heartbeat() throws -> Bool
    func stopGovernor() throws
    func invalidate()
}

public enum FanHelperTransportError: Error, Sendable, CustomStringConvertible, Equatable {
    case rejected(String)
    case unreachable(String)
    case timedOut

    public var description: String {
        switch self {
        case .rejected(let reason): return "fan helper refused: \(reason)"
        case .unreachable(let reason): return "fan helper unreachable: \(reason)"
        case .timedOut: return "fan helper did not answer in time"
        }
    }
}

/// `NSXPCConnection` transport to the helper's Mach service. The connection
/// is only created after the app's own signature passed the pinned
/// Developer ID requirement and the helper embedded in the bundle satisfied
/// the helper requirement; the system then enforces the same requirement on
/// the remote end of every message.
final class XPCFanHelperTransport: FanHelperTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var invalid = false
    private let timeout: TimeInterval

    init(
        teamID: String,
        bundledHelper: URL?,
        timeout: TimeInterval = 5,
        embeddedTeamID: String? = EmbeddedTeamIdentifier.value,
        selfValidator: any CodeRequirementValidating = SelfCodeRequirementValidator()
    ) throws {
        self.timeout = timeout
        guard let helperRequirement = CodeSigningRequirements.helperRequirement(teamID: teamID) else {
            throw FanHelperTransportError.rejected("malformed team identifier")
        }
        // "The app rejects a helper that does not satisfy the requirement":
        // refuse before connecting if the helper shipped in this bundle has
        // been swapped or re-signed.
        if let bundledHelper,
           !StaticCodeRequirementValidator(url: bundledHelper).satisfies(requirement: helperRequirement) {
            throw FanHelperTransportError.rejected("the bundled helper does not satisfy its code-signing requirement")
        }
        let connection = NSXPCConnection(
            machServiceName: FanHelperConstants.helperIdentifier, options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPCProtocol.self)
        guard FanHelperConnectionPolicy.secure(
            connection, role: .appAcceptingHelper, ownTeamID: teamID,
            embeddedTeamID: embeddedTeamID, selfValidator: selfValidator
        ) else {
            connection.invalidate()
            throw FanHelperTransportError.rejected("this app is not release-signed")
        }
        self.connection = connection
        let markInvalid: () -> Void = { [weak self] in
            self?.lock.lock()
            self?.invalid = true
            self?.lock.unlock()
        }
        connection.invalidationHandler = markInvalid
        connection.interruptionHandler = markInvalid
        connection.resume()
    }

    func startGovernor(profile: String) throws {
        let message: String? = try call { proxy, done in
            proxy.startGovernor(profile: profile) { done($0) }
        }
        if let message { throw FanHelperTransportError.rejected(message) }
    }

    func heartbeat() throws -> Bool {
        try call { proxy, done in proxy.heartbeat { done($0) } }
    }

    func stopGovernor() throws {
        let _: Bool = try call { proxy, done in proxy.stopGovernor { done(true) } }
    }

    func invalidate() { connection.invalidate() }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
        var error: Error?
    }

    private func call<T: Sendable>(
        _ body: (any FanHelperXPCProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) throws -> T {
        lock.lock()
        let dead = invalid
        lock.unlock()
        if dead { throw FanHelperTransportError.unreachable("connection lost") }

        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            box.error = FanHelperTransportError.unreachable(error.localizedDescription)
            semaphore.signal()
        }) as? any FanHelperXPCProtocol else {
            throw FanHelperTransportError.unreachable("no remote object")
        }
        body(proxy) { value in
            box.value = value
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw FanHelperTransportError.timedOut
        }
        if let error = box.error { throw error }
        guard let value = box.value else { throw FanHelperTransportError.timedOut }
        return value
    }
}

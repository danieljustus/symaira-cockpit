import Foundation
import SymCockpitCore

/// The object exported over XPC: translates the wire protocol onto the
/// engine. Holds no logic of its own beyond input validation.
final class FanHelperService: NSObject, FanHelperXPCProtocol, @unchecked Sendable {
    private let engine: FanHelperEngine

    init(engine: FanHelperEngine) { self.engine = engine }

    func startGovernor(profile: String, reply: @escaping (String?) -> Void) {
        guard let parsed = FanProfile(rawValue: profile) else {
            reply("unknown fan profile")
            return
        }
        engine.start(profile: parsed)
        reply(nil)
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        engine.heartbeat()
        reply(engine.snapshot.isGoverning)
    }

    func stopGovernor(reply: @escaping () -> Void) {
        engine.stop(reason: .requested)
        reply()
    }

    func status(reply: @escaping (String, String?) -> Void) {
        let snapshot = engine.snapshot
        if snapshot.isGoverning {
            reply("governing", snapshot.profile.rawValue)
        } else if let failure = snapshot.failure {
            reply("failed", failure)
        } else {
            reply("idle", snapshot.lastStopReason?.rawValue)
        }
    }
}

/// Accepts XPC connections for the helper's Mach service.
///
/// Only one client is served at a time. A connection is refused unless the
/// helper itself holds a valid release signature and the peer satisfies the
/// app requirement (``FanHelperConnectionPolicy``). A run belongs to the
/// connection that started it: when that connection goes away the governor
/// stops, because nothing is left to send heartbeats.
public final class FanHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine: FanHelperEngine
    private let ownTeamID: String?
    private let embeddedTeamID: String?
    private let selfValidator: any CodeRequirementValidating
    private let lock = NSLock()
    private var current: NSXPCConnection?

    public init(
        engine: FanHelperEngine,
        ownTeamID: String? = CodeSignatureInspector.ownTeamIdentifier(),
        embeddedTeamID: String? = EmbeddedTeamIdentifier.value,
        selfValidator: any CodeRequirementValidating = SelfCodeRequirementValidator()
    ) {
        self.engine = engine
        self.ownTeamID = ownTeamID
        self.embeddedTeamID = embeddedTeamID
        self.selfValidator = selfValidator
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard FanHelperConnectionPolicy.secure(
            newConnection, role: .helperAcceptingApp,
            ownTeamID: ownTeamID, embeddedTeamID: embeddedTeamID, selfValidator: selfValidator
        ) else { return false }

        newConnection.exportedInterface = NSXPCInterface(with: FanHelperXPCProtocol.self)
        newConnection.exportedObject = FanHelperService(engine: engine)

        lock.lock()
        let previous = current
        current = newConnection
        lock.unlock()

        let drop: () -> Void = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.lock.lock()
            let isCurrent = self.current === newConnection
            if isCurrent { self.current = nil }
            self.lock.unlock()
            if isCurrent { self.engine.connectionInvalidated() }
        }
        newConnection.invalidationHandler = drop
        newConnection.interruptionHandler = drop
        newConnection.resume()
        previous?.invalidate()
        return true
    }
}

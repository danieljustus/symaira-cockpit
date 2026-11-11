import Foundation
import SymCockpitCore

/// The object exported over XPC: translates the wire protocol onto the
/// engine. Holds no logic of its own beyond input validation.
final class FanHelperService: NSObject, FanHelperXPCProtocol, @unchecked Sendable {
    private let engine: FanHelperEngine

    init(engine: FanHelperEngine) { self.engine = engine }

    /// The Cool target as received over the wire.
    enum CoolTargetDecoding: Equatable {
        case none
        case value(Double)
        case malformed
    }

    /// The helper is root and does not trust the app's number: nil is "no
    /// target", a non-finite value is malformed (refused, never guessed at),
    /// and a finite one is clamped to ``FanCoolTarget/range``.
    static func decodeCoolTarget(_ raw: NSNumber?) -> CoolTargetDecoding {
        guard let raw else { return .none }
        let value = raw.doubleValue
        guard value.isFinite, let clamped = FanCoolTarget.sanitized(value) else { return .malformed }
        return .value(clamped)
    }

    func startGovernor(
        profile: String,
        coolTargetCelsius: NSNumber?,
        reply: @escaping (String?) -> Void
    ) {
        guard let parsed = FanProfile(rawValue: profile) else {
            reply("unknown fan profile")
            return
        }
        let target: Double?
        switch Self.decodeCoolTarget(coolTargetCelsius) {
        case .none: target = nil
        case .value(let value): target = value
        case .malformed:
            reply("invalid Cool target")
            return
        }
        engine.start(profile: parsed, coolTarget: target)
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

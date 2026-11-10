import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

private final class FakeDaemon: FanHelperDaemonService, @unchecked Sendable {
    private let lock = NSLock()
    var state: FanHelperRegistration
    var stateAfterRegister: FanHelperRegistration?
    var registerThrows = false
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var settingsOpened = 0

    init(_ state: FanHelperRegistration) { self.state = state }

    var registration: FanHelperRegistration { lock.lock(); defer { lock.unlock() }; return state }
    func register() throws {
        lock.lock(); registerCalls += 1
        if let stateAfterRegister { state = stateAfterRegister }
        let throwing = registerThrows
        lock.unlock()
        if throwing { throw NSError(domain: "SMAppService", code: 1) }
    }
    func unregister() throws { lock.lock(); unregisterCalls += 1; state = .notRegistered; lock.unlock() }
    func openSystemSettings() { lock.lock(); settingsOpened += 1; lock.unlock() }
}

private final class FakeTransport: FanHelperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [String] = []
    private(set) var beats = 0
    private(set) var stops = 0
    private(set) var invalidated = false
    var failHeartbeats = false

    func startGovernor(profile: String) throws { lock.lock(); started.append(profile); lock.unlock() }
    func heartbeat() throws {
        lock.lock(); defer { lock.unlock() }
        beats += 1
        if failHeartbeats { throw FanHelperTransportError.unreachable("gone") }
    }
    func stopGovernor() throws { lock.lock(); stops += 1; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var beatCount: Int { lock.lock(); defer { lock.unlock() }; return beats }
}

private final class TransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [FakeTransport] = []
    private(set) var teamIDs: [String] = []
    func make(team: String) -> FakeTransport {
        lock.lock(); defer { lock.unlock() }
        let t = FakeTransport(); made.append(t); teamIDs.append(team); return t
    }
}

final class FanHelperClientTests: XCTestCase {
    private let team = "ABCDE12345"

    private func client(
        daemon: FakeDaemon,
        signing: FanHelperSigning,
        optedIn: Bool,
        factory: TransportFactory,
        interval: TimeInterval = 0.01
    ) -> FanHelperClient {
        FanHelperClient(
            daemon: daemon, signing: { signing }, optedIn: { optedIn },
            heartbeatInterval: interval,
            makeTransport: { factory.make(team: $0) }
        )
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    // MARK: - Unsigned / local builds

    func testUnsignedBuildNeverRegistersAndNeverConnects() {
        let daemon = FakeDaemon(.notRegistered)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .unsigned, optedIn: true, factory: factory)
        XCTAssertEqual(c.availability(), .unavailable(.unsigned))
        XCTAssertThrowsError(try c.register())
        XCTAssertThrowsError(try c.startGovernor(profile: .comfort))
        XCTAssertEqual(daemon.registerCalls, 0)
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testOptedOutNeverConnectsEvenWhenRegisteredAndSigned() {
        let daemon = FakeDaemon(.enabled)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: false, factory: factory)
        XCTAssertEqual(c.availability(), .off)
        XCTAssertThrowsError(try c.startGovernor(profile: .comfort))
        XCTAssertTrue(factory.made.isEmpty)
    }

    // MARK: - Registration

    func testRegisterSurfacesPendingApprovalInsteadOfFailing() throws {
        let daemon = FakeDaemon(.notRegistered)
        daemon.stateAfterRegister = .requiresApproval
        daemon.registerThrows = true // SMAppService throws while approval is pending
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: TransportFactory())
        XCTAssertEqual(try c.register(), .requiresApproval)
        c.openSystemSettings()
        XCTAssertEqual(daemon.settingsOpened, 1)
    }

    func testRegisterPropagatesRealFailures() {
        let daemon = FakeDaemon(.notRegistered)
        daemon.registerThrows = true
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: TransportFactory())
        XCTAssertThrowsError(try c.register())
    }

    func testUnregisterStopsTheGovernorThenRemovesTheDaemon() throws {
        let daemon = FakeDaemon(.enabled)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: factory)
        try c.startGovernor(profile: .comfort)
        try c.unregister()
        XCTAssertEqual(factory.made.first?.stops, 1)
        XCTAssertEqual(daemon.unregisterCalls, 1)
        XCTAssertTrue(factory.made.first?.invalidated ?? false)
    }

    // MARK: - Heartbeat

    func testStartingTheGovernorSendsTheProfileAndHeartbeatsUntilStopped() throws {
        let daemon = FakeDaemon(.enabled)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: factory)
        try c.startGovernor(profile: .performance)
        let transport = try XCTUnwrap(factory.made.first)
        XCTAssertEqual(factory.teamIDs, [team])
        XCTAssertEqual(transport.started, ["performance"])
        XCTAssertTrue(waitUntil { transport.beatCount >= 3 })

        try c.stopGovernor()
        let afterStop = transport.beatCount
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(transport.beatCount, afterStop, "heartbeats must stop with the governor")
        XCTAssertEqual(transport.stops, 1)
    }

    func testRetargetingReusesTheConnection() throws {
        let daemon = FakeDaemon(.enabled)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: factory)
        try c.startGovernor(profile: .comfort)
        try c.startGovernor(profile: .performance)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.made[0].started, ["comfort", "performance"])
        try c.stopGovernor()
    }

    func testFailingHeartbeatDropsTheConnectionAndStopsPinging() throws {
        let daemon = FakeDaemon(.enabled)
        let factory = TransportFactory()
        let c = client(daemon: daemon, signing: .releaseSigned(teamID: team), optedIn: true, factory: factory)
        try c.startGovernor(profile: .comfort)
        let transport = try XCTUnwrap(factory.made.first)
        transport.failHeartbeats = true
        XCTAssertTrue(waitUntil { transport.invalidated })
        let beats = transport.beatCount
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(transport.beatCount, beats)

        // The next fan change reconnects with a fresh transport.
        try c.startGovernor(profile: .comfort)
        XCTAssertEqual(factory.made.count, 2)
        try c.stopGovernor()
    }

    func testAnUnreachableHelperSurfacesAsAPermissionError() {
        let daemon = FakeDaemon(.enabled)
        let signed = FanHelperSigning.releaseSigned(teamID: team)
        let c = FanHelperClient(
            daemon: daemon, signing: { signed }, optedIn: { true },
            makeTransport: { _ in throw FanHelperTransportError.rejected("not release-signed") }
        )
        XCTAssertThrowsError(try c.startGovernor(profile: .comfort)) { error in
            guard case TuneError.permission = error else { return XCTFail("\(error)") }
        }
    }
}

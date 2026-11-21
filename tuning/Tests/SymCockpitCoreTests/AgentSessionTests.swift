import XCTest
@testable import SymCockpitCore

/// `AgentSession` against the fake agent (Fixtures/fake-agent.pl, a Perl script
/// that speaks docs/agent-protocol.md from a fixtures file). No Rust binary,
/// hardware or permission is involved. The fixtures keep the shape of a real
/// `symcockpit` 0.12.2 capture; names and volumes are scrubbed.
final class AgentSessionTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.log") }

    private static var fixtureDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AgentEvent] = []
        private var _states: [AgentState] = []
        var events: [AgentEvent] { lock.withLock { _events } }
        var states: [AgentState] { lock.withLock { _states } }
        func add(_ event: AgentEvent) { lock.withLock { _events.append(event) } }
        func add(_ state: AgentState) { lock.withLock { _states.append(state) } }
        func events(of command: String) -> [AgentEvent] { events.filter { $0.command == command } }
    }

    private func session(_ scenario: String = "ok") -> AgentSession {
        AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [Self.fixtureDirectory.appendingPathComponent("fake-agent.pl").path, scenario],
            environment: [
                "FAKE_AGENT_FIXTURES": Self.fixtureDirectory.appendingPathComponent("agent-fixtures.json").path,
                "FAKE_AGENT_LOG": log.path,
                "FAKE_AGENT_MARKER": directory.appendingPathComponent("crashed").path,
            ],
            startTimeout: 10, requestTimeout: 5
        ))
    }

    /// The parameters of every request of `method` the fake received, in order.
    private func requests(_ method: String) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").compactMap { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["method"] as? String == method ? object?["params"] as? [String: Any] : nil
        }
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    // MARK: - Lifecycle

    func testStartReachesReadyWithTheAgentsVersionAndStopEndsIt() async {
        let agent = session()
        let recorder = Recorder()
        agent.addStateObserver { recorder.add($0) }
        await agent.start()
        guard case .ready(let hello) = agent.state else { return XCTFail("\(agent.state)") }
        XCTAssertEqual(hello.serverVersion, "9.9.9-fake")
        XCTAssertEqual(agent.hello, hello)
        agent.stop()
        XCTAssertEqual(agent.state, .stopped)
        XCTAssertEqual(recorder.states, [.starting, .ready(hello), .stopped])
    }

    func testAMissingExecutableIsADiagnosisNotACrash() async {
        let agent = AgentSession(configuration: .init(executable: directory.appendingPathComponent("no-such-agent")))
        await agent.start()
        guard case .failed(.executableMissing) = agent.state else { return XCTFail("\(agent.state)") }
        let diagnosis = AgentDiagnosis.of(agent.state)
        XCTAssertEqual(diagnosis?.title, "Cockpit agent missing")
        XCTAssertTrue(diagnosis?.detail.contains("no-such-agent") ?? false)
        // An action on a dead agent is a failure the UI can show, not a value.
        let outcome = await agent.perform("metrics")
        XCTAssertNotNil(outcome.failureMessage)
    }

    func testAVersionConflictIsADiagnosisNamingBothVersions() async {
        let agent = session("version")
        await agent.start()
        XCTAssertEqual(agent.state, .failed(.versionMismatch(clientVersion: 1, agentVersions: [7])))
        let diagnosis = AgentDiagnosis.of(agent.state)
        XCTAssertEqual(diagnosis?.title, "Cockpit agent has another version")
        XCTAssertTrue(diagnosis?.detail.contains("version 7") ?? false)
    }

    func testAnAgentThatRefusesItsParentIsADiagnosisWithItsReason() async {
        let agent = session("refuse")
        await agent.start()
        let diagnosis = AgentDiagnosis.of(agent.state)
        XCTAssertEqual(diagnosis?.title, "Cockpit agent refused to start")
        XCTAssertTrue(diagnosis?.detail.contains("not the signed com.symaira.cockpit app") ?? false, "\(String(describing: diagnosis))")
    }

    func testARunningAgentIsNoDiagnosis() async {
        let agent = session()
        await agent.start()
        defer { agent.stop() }
        XCTAssertNil(AgentDiagnosis.of(agent.state))
    }

    func testACrashedAgentIsADiagnosisAndARestartBringsTheSubscriptionsBack() async throws {
        let agent = session("crash_once")
        let recorder = Recorder()
        _ = agent.subscribe("fan.status") { recorder.add($0) }
        await agent.start()
        defer { agent.stop() }
        waitFor("the first sample") { recorder.events(of: "fan.status").count == 1 }

        let outcome = await agent.perform("die")
        XCTAssertNotNil(outcome.failureMessage)
        waitFor("the failed state") { if case .failed(.exited(7, _)) = agent.state { return true } else { return false } }
        XCTAssertEqual(AgentDiagnosis.of(agent.state)?.title, "Cockpit agent stopped")

        await agent.restart()
        guard case .ready = agent.state else { return XCTFail("\(agent.state)") }
        // The new process serves the same subscription again, counting from 1.
        waitFor("the sample after the restart") { recorder.events(of: "fan.status").count == 2 }
        XCTAssertEqual(recorder.events(of: "fan.status").map(\.sequence), [1, 1])
        XCTAssertEqual(try requests("subscribe").count, 2)
    }

    // MARK: - Subscriptions

    func testSubscriptionsDeliverEveryEventInOrderIncludingTheFirstOne() async throws {
        let agent = session()
        let recorder = Recorder()
        await agent.start()
        defer { agent.stop() }
        _ = agent.subscribe("metrics", visibleMs: 1000) { recorder.add($0) }
        _ = agent.subscribe("brightness.get") { recorder.add($0) }
        await agent.settled()
        // The first sample follows the subscribe answer at once; it must not be lost.
        waitFor("both first samples") { recorder.events.count == 2 }
        _ = await agent.perform("__tick")
        waitFor("both second samples") { recorder.events.count == 4 }
        XCTAssertEqual(recorder.events(of: "metrics").map(\.sequence), [1, 2])
        XCTAssertEqual(recorder.events(of: "brightness.get").map(\.sequence), [1, 2])
        XCTAssertEqual(try requests("subscribe").first?["interval_visible_ms"] as? Int, 1000)
    }

    func testAnUnsubscribedViewGetsNoMoreEventsAndTheAgentIsTold() async throws {
        let agent = session()
        let recorder = Recorder()
        await agent.start()
        defer { agent.stop() }
        let token = agent.subscribe("metrics") { recorder.add($0) }
        waitFor("the first sample") { recorder.events.count == 1 }
        agent.unsubscribe(token)
        await agent.settled()
        _ = await agent.perform("__tick")
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(try requests("unsubscribe").count, 1)
    }

    func testASubscriptionMadeBeforeTheAgentIsUpIsActivatedWhenItIsReady() async {
        let agent = session()
        let recorder = Recorder()
        _ = agent.subscribe("awake.status") { recorder.add($0) }
        XCTAssertTrue(recorder.events.isEmpty)
        await agent.start()
        defer { agent.stop() }
        waitFor("the sample") { recorder.events.count == 1 }
    }

    func testARefusedSubscriptionReachesTheHandlerAsOneEndedErrorEvent() async {
        let agent = session()
        let recorder = Recorder()
        await agent.start()
        defer { agent.stop() }
        _ = agent.subscribe("fan.set") { recorder.add($0) }
        waitFor("the error event") { recorder.events.count == 1 }
        guard case .error(let error)? = recorder.events.first?.payload else { return XCTFail("\(recorder.events)") }
        XCTAssertEqual(error.code, -32602)
        XCTAssertEqual(recorder.events.first?.ended, true)
    }

    // MARK: - Visibility

    func testTheAgentIsToldOnlyWhenTheSetOfVisibleViewsChangesBetweenNoneAndSome() async throws {
        let agent = session()
        await agent.start()
        defer { agent.stop() }
        func sent() throws -> [Bool] { try requests("set_visibility").compactMap { $0["visible"] as? Bool } }
        // Nothing on screen yet: the agent, which starts visible, is told to slow down once.
        XCTAssertEqual(try sent(), [false])
        agent.setVisible(true, owner: "popover")
        agent.setVisible(true, owner: "window")
        agent.setVisible(false, owner: "popover")
        await agent.settled()
        XCTAssertEqual(try sent(), [false, true], "the window is still visible")
        agent.setVisible(false, owner: "window")
        await agent.settled()
        XCTAssertEqual(try sent(), [false, true, false])
    }

    // MARK: - Actions

    func testAReversibleCommandRunsAtOnceAndAReadReturnsItsOutput() async {
        let agent = session()
        await agent.start()
        defer { agent.stop() }
        let set = await agent.perform("brightness.set", params: ["value": .number(0.8)])
        XCTAssertEqual(set, .done(.object(["applied": .bool(true)])))
        guard case .done(let output) = await agent.perform("brightness.get") else { return XCTFail() }
        XCTAssertEqual(output["brightness"], .number(0.8))
    }

    func testARiskyCommandIsOnlyPlannedAndRunsOnConfirmation() async throws {
        let agent = session()
        await agent.start()
        defer { agent.stop() }
        let outcome = await agent.perform("fan.profile", params: ["profile": .string("comfort")])
        guard case .needsConfirmation(let plan) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(plan.command, "fan.profile")
        XCTAssertEqual(plan.expiresInSeconds, 300)
        XCTAssertEqual(plan.items.map(\.target), ["fan.profile"])
        XCTAssertEqual(plan.items.first?.params["profile"], .string("comfort"))
        // Nothing has changed before the user confirms.
        guard case .done(let before) = await agent.perform("fan.status") else { return XCTFail() }
        XCTAssertEqual(before["profile"], .string("system"))

        let confirmed = await agent.confirm(plan)
        XCTAssertEqual(confirmed, .done(.object(["applied": .bool(true)])))
        guard case .done(let after) = await agent.perform("fan.status") else { return XCTFail() }
        XCTAssertEqual(after["profile"], .string("comfort"))
        // A plan confirms once.
        let again = await agent.confirm(plan)
        XCTAssertNotNil(again.failureMessage)
    }

    func testAFailedConfirmationAndACommandErrorKeepTheirExitClass() async {
        let denied = session("confirm_denied")
        await denied.start()
        defer { denied.stop() }
        guard case .needsConfirmation(let plan) = await denied.perform("fan.profile", params: ["profile": .string("performance")]) else {
            return XCTFail()
        }
        let refused = await denied.confirm(plan)
        XCTAssertEqual(refused, .failed(message: "permission error: the fan helper is not approved", exitClass: "permission"))
        let failed = await denied.perform("fail.permission")
        XCTAssertEqual(failed, .failed(message: "permission error: access was not granted", exitClass: "permission"))
    }

    func testTheRegisterTellsWhichArgumentAFanCommandTakes() async {
        let agent = session()
        XCTAssertNil(agent.argumentName(of: "fan.profile"), "no hello yet")
        await agent.start()
        defer { agent.stop() }
        XCTAssertEqual(agent.argumentName(of: "fan.profile"), "profile")
        XCTAssertEqual(agent.argumentName(of: "fan.target"), "target")
        XCTAssertEqual(agent.clearValue(of: "fan.target"), .string("off"))
        XCTAssertNil(agent.argumentName(of: "fan.set"), "an agent whose command takes no argument cannot set it")
        XCTAssertNil(agent.argumentName(of: "no.such.command"))
        XCTAssertEqual(agent.clearValue(of: "fan.set"), .null)
    }

    // MARK: - Decoding

    private func fixture(_ command: String) throws -> AgentJSON {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("agent-fixtures.json"))
        return try XCTUnwrap(JSONDecoder().decode(AgentJSON.self, from: data)[command])
    }

    func testTheAgentsAnswersDecodeIntoTheCoreReports() throws {
        let status = try AgentDecoding.decode(StatusReport.self, from: fixture("status"))
        // `display_id` is an acronym key the stock snake-case strategy cannot produce.
        XCTAssertEqual(status.displays.displays.first?.displayID, 1)
        XCTAssertEqual(status.displays.displays.first?.isBuiltin, true)
        XCTAssertEqual(status.sensors.fans.count, 2)
        XCTAssertEqual(status.battery.present, true)
        XCTAssertNil(status.activeOverrides.dim)

        let metrics = try AgentDecoding.decode(SystemMetricsReport.self, from: fixture("metrics"))
        XCTAssertEqual(metrics.cpu.totalUtilization, 12.5)
        XCTAssertEqual(metrics.volumes.map(\.name), ["Macintosh HD", "Example"])
        XCTAssertNotNil(metrics.memory.usedBytes)

        let fan = try AgentDecoding.decode(FanStatus.self, from: fixture("fan.status"))
        XCTAssertEqual(fan, FanStatus(profile: .system, governorRunning: false, coolTargetCelsius: nil, averageClusterCelsius: 61.2))

        let awake = try AgentDecoding.decode(KeepAwakeSession.self, from: fixture("awake.status"))
        XCTAssertFalse(awake.active)
        XCTAssertEqual(try AgentDecoding.decode(BrightnessReadback.self, from: fixture("brightness.get")).brightness, 0.5)

        let processes = try AgentDecoding.decode(ProcessUsageReport.self, from: fixture("processes"))
        XCTAssertEqual(processes.sortedBy, .cpu)
        XCTAssertEqual(processes.processes.count, 3)
    }

    func testProviderResultsKeepTheirProviderIDInTheRowAndInsideTheSnapshot() throws {
        let results = try AgentDecoding.decode([AIUsageService.ProviderResult].self, from: fixture("ai-usage"))
        XCTAssertEqual(results.map(\.providerID), ["p", "q"])
        XCTAssertEqual(results[0].error, "not configured")
        XCTAssertNil(results[0].snapshot)
        XCTAssertEqual(results[1].snapshot?.providerID, "q")
    }
}

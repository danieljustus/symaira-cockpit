import XCTest
@testable import SymCockpitCore
@testable import SymCockpitUI

/// The app's view models against the fake agent (tuning/Tests/SymCockpitCoreTests/Fixtures/fake-agent.pl,
/// shape of a real symcockpit capture): readings only from agent events, actions
/// as agent commands, the plan the user confirms in the app, and the diagnosis
/// while the agent is not there. No Rust binary, hardware, controller or
/// permission is involved.
@MainActor
final class AgentViewModelTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.log") }

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tuning/Tests/SymCockpitCoreTests/Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-viewmodel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(_ scenario: String = "ok") -> AgentSession {
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

    private func makeModel(_ session: AgentSession) -> TuneViewModel {
        let name = NSTemporaryDirectory() + "AgentViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return TuneViewModel(session: session, preferences: PreferencesManager(defaults: defaults))
    }

    /// The parameters of every request of `method` the fake received, in order.
    private func requests(_ method: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            return object?["method"] as? String == method ? object?["params"] as? [String: Any] : nil
        }
    }

    private func subscribed() -> [String] { requests("subscribe").compactMap { $0["command"] as? String } }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    // MARK: - Readings

    func testNothingIsShownBeforeTheAgentAnswersAndOnlyWhatItSentAfterwards() async {
        let session = makeSession()
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        XCTAssertNil(model.metrics)
        XCTAssertNil(model.diagnosis)
        XCTAssertTrue(model.statusItemText.isEmpty)

        model.start()
        await session.start()
        await waitFor("the first metrics sample") { model.metrics != nil }
        XCTAssertEqual(model.metrics?.cpu.totalUtilization, 12.5)
        XCTAssertEqual(model.storageVolumes?.map(\.name), ["Macintosh HD", "Example"])
        XCTAssertFalse(model.statusItemText.isEmpty)
        XCTAssertTrue(model.isAgentReady)
        // The sparkline history is fed from received samples only.
        XCTAssertFalse(model.metricRows.isEmpty)
        // Not measured: nothing of the detail surface exists yet.
        XCTAssertNil(model.sensors)
        XCTAssertEqual(subscribed(), ["metrics"])
    }

    func testTheDetailSurfaceSubscribesOnlyWhileItIsVisible() async {
        let session = makeSession()
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        await waitFor("metrics") { model.metrics != nil }

        model.setDetailVisible(true)
        await waitFor("the detail readings") { model.sensors != nil && model.battery != nil && !model.displays.isEmpty }
        await waitFor("fan and awake status") { model.fanAverageClusterCelsius != nil }
        XCTAssertEqual(model.displays.first?.displayID, 1)
        XCTAssertEqual(model.sensors?.fans.count, 2)
        XCTAssertEqual(model.fanProfile, .system)
        XCTAssertFalse(model.keepAwake.active)
        XCTAssertEqual(model.builtinBrightness, 0.5)
        XCTAssertEqual(Set(subscribed()), ["metrics", "status", "brightness.get", "awake.status", "fan.status"])

        model.setDetailVisible(false)
        await session.settled()
        XCTAssertEqual(requests("unsubscribe").count, 4, "closing the panel ends its four subscriptions, not the menu-bar metrics")
        // The agent hears about the views: slowed down once the priming ended, speeding up and down with the panel.
        let visibility = requests("set_visibility").compactMap { $0["visible"] as? Bool }
        XCTAssertEqual(visibility, [false, true, false])
    }

    func testProcessesAreSampledOnlyWhileTheCardIsVisible() async {
        let session = makeSession()
        let model = ProcessesViewModel(session: session)
        await session.start()
        defer { session.stop() }
        XCTAssertTrue(subscribed().isEmpty)

        model.setVisible(true)
        await waitFor("the process list") { model.report.processes.count == 3 }
        XCTAssertFalse(model.isWarmingUp)
        XCTAssertEqual(model.report.processes.first?.name, "Example App 1")
        let request = requests("subscribe").first
        XCTAssertEqual(request?["command"] as? String, "processes")
        XCTAssertEqual((request?["params"] as? [String: Any])?["sort_by"] as? String, "cpu")
        XCTAssertEqual((request?["params"] as? [String: Any])?["limit"] as? Int, 6)

        model.setVisible(false)
        await session.settled()
        XCTAssertTrue(model.report.processes.isEmpty, "a stale list is dropped")
        XCTAssertEqual(requests("unsubscribe").count, 1)
    }

    func testAIUsageRowsComeFromTheAgentAndOnlyForTheProvidersAsked() async {
        let session = makeSession()
        await session.start()
        defer { session.stop() }
        let results = await AIUsageViewModel.usage(from: session, selected: ["q"])
        XCTAssertEqual(results.map(\.providerID), ["q"])
        XCTAssertEqual(results.first?.snapshot?.providerID, "q")
        // The selection travels with the request, so the agent asks symbrain for it only.
        let call = requests("call").last { $0["command"] as? String == "ai-usage" }
        XCTAssertEqual((call?["params"] as? [String: Any])?["providers"] as? [String], ["q"])
    }

    func testAIUsageWithNothingSelectedAsksTheAgentNothing() async {
        let session = makeSession()
        await session.start()
        defer { session.stop() }
        let results = await AIUsageViewModel.usage(from: session, selected: [])
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(requests("call").contains { $0["command"] as? String == "ai-usage" })
    }

    // MARK: - Actions

    func testAReversibleActionRunsAtOnceAndTheReadingFollows() async {
        let session = makeSession()
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        model.setDetailVisible(true)
        await waitFor("brightness") { model.sensors != nil }

        let outcome = await model.setBrightness(0.8)
        XCTAssertEqual(outcome, .done(.object(["applied": .bool(true)])))
        await waitFor("the new brightness") { model.builtinBrightness == 0.8 }

        _ = await model.setBeyondNormal(dimFactor: 0.5, extendedBrightness: nil)
        await waitFor("the dim level") { model.dimAmount == 0.5 }
        let awake = await model.setKeepAwake(true, preventDisplaySleep: true, duration: 900)
        XCTAssertEqual(awake, .done(.object(["applied": .bool(true)])))
        await waitFor("keep awake") { model.keepAwake.active }
        let sent = requests("call").first { ($0["command"] as? String) == "awake" }
        XCTAssertEqual((sent?["params"] as? [String: Any])?["duration_seconds"] as? Double, 900)
    }

    func testAFanChangeIsPlannedFirstAndOnlyAppliedWhenTheUserConfirms() async {
        let session = makeSession()
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        model.setDetailVisible(true)
        await waitFor("fan status") { model.fanAverageClusterCelsius != nil }

        await model.requestFanProfile(.comfort)
        let pending = model.pendingFanChange
        XCTAssertEqual(pending?.summary, "Set the fan control to Cool.")
        XCTAssertEqual(pending?.plan.items.first?.target, "fan.profile")
        XCTAssertEqual(model.fanProfile, .system, "nothing changes before the user confirms")

        // Cancel: the plan is dropped, still nothing changed.
        model.cancelPendingFanChange()
        XCTAssertNil(model.pendingFanChange)
        XCTAssertEqual(model.fanProfile, .system)

        await model.requestFanProfile(.comfort)
        await model.confirmPendingFanChange()
        // The result stays on screen until the user says Done; the controls are free again.
        XCTAssertEqual(model.pendingFanChange?.confirmation.report?.status, .confirmed)
        XCTAssertEqual(model.pendingFanChange?.isOpen, false)
        XCTAssertNil(model.fanFailure)
        await waitFor("the confirmed profile") { model.fanProfile == .comfort }
        model.dismissPendingFanChange()
        XCTAssertNil(model.pendingFanChange)

        // The Cool target goes the same way, and "off" is the clearing value of the register.
        await model.requestFanCoolTarget(70)
        XCTAssertEqual(model.pendingFanChange?.summary, "Cool the Mac at a maximum average of 70 °C.")
        await model.confirmPendingFanChange()
        await waitFor("the target") { model.fanCoolTarget == 70 }
        await model.requestFanCoolTarget(nil)
        await model.confirmPendingFanChange()
        await waitFor("the cleared target") { model.fanCoolTarget == nil }
        let confirms = requests("confirm").count
        XCTAssertEqual(confirms, 3)
    }

    func testAChargeLimitIsPlannedFirstAndNamedOnlyAfterTheUserConfirms() async {
        let session = makeSession()
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()

        await model.requestChargeLimit(80)
        XCTAssertEqual(model.pendingChargeChange?.summary, "Stop charging at 80 %.")
        XCTAssertEqual(model.pendingChargeChange?.plan.command, "battery-limit.set")
        XCTAssertEqual(requests("confirm").count, 0, "nothing is sent before the user confirms")
        XCTAssertNil(model.chargeLimitThisSession, "the app does not claim a limit it did not apply")

        await model.pendingChargeChange?.confirmation.confirm()
        XCTAssertEqual(model.chargeLimitThisSession, .some(80))
        XCTAssertNil(model.chargeFailure)
        model.dismissPendingChargeChange()

        await model.requestChargeLimit(nil)
        XCTAssertEqual(model.pendingChargeChange?.plan.command, "battery-limit.clear")
        await model.pendingChargeChange?.confirmation.confirm()
        XCTAssertEqual(model.chargeLimitThisSession, .some(nil))
        XCTAssertEqual(requests("confirm").count, 2)
    }

    func testADeniedChargeLimitShowsTheReasonAndNoLimit() async {
        let session = makeSession("confirm_denied")
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        await model.requestChargeLimit(70)
        await model.pendingChargeChange?.confirmation.confirm()
        XCTAssertNil(model.pendingChargeChange)
        XCTAssertNil(model.chargeLimitThisSession)
        XCTAssertTrue(model.chargeFailure?.contains("fan helper is not approved") ?? false)
    }

    func testADeniedFanChangePointsToTheHelper() async {
        let session = makeSession("confirm_denied")
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        await model.requestFanProfile(.performance)
        XCTAssertNotNil(model.pendingFanChange)
        await model.confirmPendingFanChange()
        XCTAssertNil(model.pendingFanChange)
        XCTAssertEqual(model.fanFailure?.needsHelper, true)
        XCTAssertTrue(model.fanFailure?.message.contains("fan helper is not approved") ?? false)
    }

    // MARK: - Diagnosis

    func testAMissingAgentShowsADiagnosisAndNoValues() async {
        let session = AgentSession(configuration: .init(executable: directory.appendingPathComponent("symcockpit")))
        let model = makeModel(session)
        defer { model.stop() }
        model.start()
        await session.start()
        await waitFor("the diagnosis") { model.diagnosis != nil }
        XCTAssertEqual(model.diagnosis?.title, "Cockpit agent missing")
        XCTAssertFalse(model.isAgentReady)
        XCTAssertNil(model.metrics)
        XCTAssertTrue(model.metricRows.isEmpty)
        XCTAssertTrue(model.statusItemText.isEmpty, "no readout without a reading")
        let outcome = await model.setBrightness(0.5)
        XCTAssertNotNil(outcome.failureMessage)
    }

    func testALostAgentClearsEveryReadingAndARestartBringsThemBack() async {
        let session = makeSession("crash_once")
        let model = makeModel(session)
        defer { model.stop(); session.stop() }
        model.start()
        await session.start()
        model.setDetailVisible(true)
        await waitFor("readings") { model.metrics != nil && model.sensors != nil }

        _ = await session.perform("die")
        await waitFor("the diagnosis") { model.diagnosis != nil }
        XCTAssertEqual(model.diagnosis?.title, "Cockpit agent stopped")
        XCTAssertNil(model.metrics)
        XCTAssertNil(model.sensors)
        XCTAssertNil(model.battery)
        XCTAssertTrue(model.displays.isEmpty)
        XCTAssertTrue(model.statusItemText.isEmpty)

        model.restartAgent()
        await waitFor("the readings after the restart") { model.metrics != nil && model.sensors != nil }
        XCTAssertNil(model.diagnosis)
        XCTAssertTrue(model.isAgentReady)
    }
}

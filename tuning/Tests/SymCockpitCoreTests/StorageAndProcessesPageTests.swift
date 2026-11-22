import XCTest
@testable import SymCockpitCore

@MainActor
final class StorageAndProcessesPageTests: XCTestCase {
    private let folder = "/Users/example/Documents"
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.jsonl") }
    private var session: AgentSession?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-and-processes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        session?.stop()
        session = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func started(_ scenario: String = "ok") async throws -> AgentSession {
        let fixtures = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [fixtures.appendingPathComponent("fake-agent.pl").path, scenario],
            environment: [
                "FAKE_AGENT_FIXTURES": fixtures.appendingPathComponent("storage-page-agent-fixtures.json").path,
                "FAKE_AGENT_LOG": log.path,
            ],
            startTimeout: 10, requestTimeout: 5
        ))
        self.session = session
        await session.start()
        XCTAssertNotNil(session.hello)
        return session
    }

    private func calls(_ command: String) throws -> [AgentJSON] {
        try requests("call").compactMap {
            guard $0["command"]?.stringValue == command else { return nil }
            return $0["params"]
        }
    }

    private func requests(_ method: String) throws -> [AgentJSON] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            let request = try JSONDecoder().decode(AgentJSON.self, from: Data(line.utf8))
            return request["method"]?.stringValue == method ? request["params"] : nil
        }
    }

    func testReadsSMARTJudgmentsAndRecordedHistoryIndependently() async throws {
        let session = try await started()
        let model = StorageHealthModel(session: session)
        await model.load()
        let report = try XCTUnwrap(model.report.value)
        XCTAssertEqual(report.overallGrade, .warning)
        XCTAssertEqual(report.devices.first?.checks.first?.rule, "temperature")
        XCTAssertEqual(report.devices.first?.metrics?.temperatureCelsius?.value, 71.5)
        XCTAssertEqual(report.devices.last?.access.status, "error")
        XCTAssertNil(report.devices.last?.metrics)
        XCTAssertEqual(model.history.value?.first?.changes?.first?.kind, "media_errors")
        XCTAssertEqual(try calls("storage.health"), [.object([:])])
        XCTAssertEqual(try calls("storage.health.history"), [.object(["limit": .number(40)])])
    }

    func testReadFailuresPreserveUnsupportedAndPermissionStates() async throws {
        let session = try await started("storage-errors")
        let health = StorageHealthModel(session: session)
        await health.load()
        XCTAssertEqual(health.report, .unavailable("no SMART-capable NVMe device found"))
        XCTAssertEqual(health.history.value?.count, 1)

        let space = SpaceModel(session: session, gate: AgentWorkGate())
        await space.analyze(folder)
        XCTAssertEqual(space.state, .unavailable("access denied to the selected folder"))
    }

    func testSpaceUsesChosenDepthAndRetainsAggregatedChildren() async throws {
        let session = try await started()
        let model = SpaceModel(session: session, gate: AgentWorkGate())
        model.depth = 4
        await model.analyze(folder)
        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.depth, 4)
        XCTAssertEqual(report.root.allocatedBytes, 12_288)
        XCTAssertEqual(report.root.children?.first?.children?.first?.id, "\(folder)/Media/clip.mov")
        XCTAssertEqual(report.root.children?.last?.allocatedBytes, 4096)
        XCTAssertTrue(report.truncated)
        XCTAssertEqual(report.errorCount, 1)
        XCTAssertEqual(try calls("storage.space"), [.object(["path": .string(folder), "depth": .number(4)])])
    }

    func testCleanupReadsCategorySizesAndUsesAreaConfirmationForPartialReport() async throws {
        let session = try await started()
        let model = CleanModel(session: session, gate: AgentWorkGate())
        XCTAssertFalse(model.selected.contains("empty_trash"))
        await model.scanSelected()
        let scan = try XCTUnwrap(model.scan.value)
        XCTAssertEqual(scan.categories.map(\.bytes), [4096, 8192, 0])
        XCTAssertEqual(scan.totalBytes, 12_288)
        XCTAssertEqual(scan.skipped, 1)
        XCTAssertEqual(try calls("storage.clean"), [
            .object(["categories": .array([.string("user_caches"), .string("user_logs"), .string("xcode_derived_data")])]),
        ])
        model.review()
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertTrue(try calls("plan.confirm").isEmpty)
        let report = await confirmation.confirm()
        XCTAssertEqual(report?.items.map(\.outcome), [.confirmed, .skippedChanged])
        XCTAssertEqual(report?.headline, "Partly applied")
        XCTAssertEqual(try calls("plan.confirm"), [.object(["plan_id": .string("pl_clean")])])
        XCTAssertTrue(try requests("confirm").isEmpty)
    }

    func testDuplicateRemovalKeepsOneCopyInEveryGroupAndUsesScannedParameters() async throws {
        let session = try await started()
        let model = DuplicatesModel(session: session, gate: AgentWorkGate())
        model.minimumSize = 1 << 20
        await model.search(folder)
        let scan = try XCTUnwrap(model.state.value)
        let group = try XCTUnwrap(scan.groups.first)
        for path in group.files { model.toggle(path, in: group) }
        XCTAssertEqual(model.selectedCount, 2)
        let finalCopy = try XCTUnwrap(group.files.last)
        XCTAssertFalse(model.canMark(finalCopy, in: group))
        XCTAssertFalse(model.isSelected(finalCopy))
        model.markAllButFirst()
        for group in scan.groups {
            let keepers = group.files.filter { !model.isSelected($0) }
            XCTAssertEqual(keepers, Array(group.files.prefix(1)))
        }

        // An edited picker should not change the parameters of the displayed search.
        model.minimumSize = 10 << 20
        await model.requestRemoval()
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.plan.items.count, 3)
        let chosen = scan.groups.flatMap { $0.files.dropFirst() }.sorted().map(AgentJSON.string)
        XCTAssertEqual(try calls("storage.duplicates.remove"), [
            .object(["path": .string(folder), "min_size": .number(1_048_576), "select": .array(chosen)]),
        ])
        XCTAssertTrue(try calls("plan.confirm").isEmpty)
    }

    func testUninstallShowsAppLeftoversAndAgentExclusionsBeforeReview() async throws {
        let session = try await started()
        let model = UninstallModel(session: session, gate: AgentWorkGate())
        let app = "/Applications/Example.app"
        await model.plan(appPath: app)
        let plan = try XCTUnwrap(model.state.value)
        XCTAssertEqual(plan.bundleID, "com.example.app")
        XCTAssertEqual(plan.items.map(\.category), ["application", "preferences"])
        XCTAssertEqual(plan.excluded.first?.reason, "documents are never removed")
        XCTAssertEqual(plan.totalBytes, 16_384)
        model.review()
        XCTAssertEqual(model.confirmation?.plan.id, "pl_uninstall")
        XCTAssertEqual(try calls("apps.uninstall"), [.object(["app": .string(app)])])
        XCTAssertTrue(try calls("plan.confirm").isEmpty)
    }

    func testSpeedTestUsesSelectedVolumeAndShowsCacheAndCleanupResults() async throws {
        let session = try await started()
        let model = SpeedtestModel(session: session, gate: AgentWorkGate())
        model.chooseTarget("/Volumes/Test")
        model.sizeMiB = 64
        await model.run()
        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.write.mibPerS, 256)
        XCTAssertEqual(report.read.mibPerS, 512)
        XCTAssertFalse(report.cacheModeApplied)
        XCTAssertFalse(report.cleanup.removed)
        XCTAssertEqual(report.cleanup.error, "permission denied")
        XCTAssertEqual(try calls("storage.speedtest"), [.object(["path": .string("/Volumes/Test"), "size_mib": .number(64)])])
    }

    func testProtectedProcessesNeverRequestAPlanAndDenialExplainsOwnership() async throws {
        let session = try await started("storage-errors")
        let model = ProcessKillModel(session: session)
        XCTAssertNotNil(model.protection(for: 1))
        let agentPID = try XCTUnwrap(session.processID)
        XCTAssertEqual(model.protection(for: agentPID), "Protected Cockpit agent process.")
        await model.request(pid: 1, name: "launchd")
        await model.request(pid: agentPID, name: "symcockpit")
        XCTAssertTrue(try calls("processes.kill").isEmpty)

        await model.request(pid: 42, name: "Example")
        XCTAssertEqual(model.refusal(for: 42, name: "Example"), "Example (pid 42) belongs to another user")
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(try calls("plan.confirm").isEmpty)
    }

    func testProcessTerminationWaitsForConfirmationAndReportsStillRunning() async throws {
        let session = try await started()
        var refreshed = false
        let model = ProcessKillModel(session: session, didFinish: { refreshed = true })
        await model.request(pid: 42, name: "Example")
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.plan.items.first?.target, "Example (pid 42)")
        XCTAssertEqual(try calls("processes.kill"), [.object(["pid": .number(42)])])
        XCTAssertTrue(try calls("plan.confirm").isEmpty)
        XCTAssertFalse(refreshed)

        let report = await confirmation.confirm()
        XCTAssertEqual(report?.status, .unconfirmed)
        XCTAssertEqual(report?.headline, "Outcome not verified")
        XCTAssertEqual(report?.items.first?.detail, "still running 3 s after SIGTERM")
        XCTAssertTrue(refreshed)
        XCTAssertEqual(try calls("plan.confirm"), [.object(["plan_id": .string("pl_kill")])])
        XCTAssertTrue(try requests("confirm").isEmpty)
    }
}

import XCTest
@testable import SymCockpitCore

/// `ClipboardModel` and `FinderModel` against the fake agent (Fixtures/fake-agent.pl): no Rust
/// binary, no pasteboard, no Keychain, no real file. The fake keeps the history in memory.
@MainActor
final class ClipboardFinderModelTests: XCTestCase {
    // XCTest calls the synchronous setup and teardown off the actor; the test itself is serial.
    nonisolated(unsafe) private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.log") }
    nonisolated(unsafe) private var sessions: [AgentSession] = []

    private static var fixtureDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-finder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func started(fixtures: [String: Any] = [:], noHost: Bool = false) async throws -> AgentSession {
        let path = directory.appendingPathComponent("fixtures.json")
        try JSONSerialization.data(withJSONObject: fixtures).write(to: path)
        var environment = ["FAKE_AGENT_FIXTURES": path.path, "FAKE_AGENT_LOG": log.path]
        if noHost { environment["FAKE_AGENT_NO_HOST"] = "1" }
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [Self.fixtureDirectory.appendingPathComponent("fake-agent.pl").path, "ok"],
            environment: environment, startTimeout: 10, requestTimeout: 5
        ))
        sessions.append(session)
        await session.start()
        return session
    }

    private static let items: [[String: Any]] = [
        ["id": "c2", "created_at": 1_790_000_200, "kind": "text", "size": 12, "source": "com.apple.Safari",
         "text": "\n  first line\nsecond line"],
        ["id": "c1", "created_at": 1_790_000_100, "kind": "text", "size": 5, "source": "com.apple.Terminal", "text": "hello"],
    ]

    private func seeded(enabled: Bool = true) -> [String: Any] {
        ["__clipboard": [
            "settings": ["enabled": enabled, "paused": false, "excluded_apps": ["com.1password.1password"],
                         "max_items": 500, "max_age_secs": 2_592_000, "max_item_bytes": 5_242_880],
            "items": Self.items,
        ]]
    }

    private func requests() throws -> String { try String(contentsOf: log, encoding: .utf8) }

    private func eventually(_ what: String, _ check: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Clipboard

    func testTheHistoryIsOffAndEmptyUntilTheUserTurnsItOn() async throws {
        let model = ClipboardModel(session: try await started())
        XCTAssertTrue(model.isOffered)
        await model.load()
        let snapshot = try XCTUnwrap(model.state.value)
        XCTAssertFalse(snapshot.settings.enabled)
        XCTAssertFalse(snapshot.settings.isCapturing)
        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(snapshot.settings.maxAgeDays, 30)
    }

    func testTheListHasMetadataOnlyAndAnEntryOpensWithSourceAndText() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        model.setVisible(true)
        await model.load()
        let snapshot = try XCTUnwrap(model.state.value)
        XCTAssertEqual(snapshot.items.map(\.id), ["c2", "c1"])
        XCTAssertEqual(snapshot.items[0].date, Date(timeIntervalSince1970: 1_790_000_200))
        XCTAssertTrue(snapshot.items[0].isText)
        XCTAssertNil(model.details["c2"], "no content is read before an entry is opened")
        XCTAssertFalse(try requests().contains("clipboard.read"))

        await model.loadDetail("c2")
        let detail = try XCTUnwrap(model.details["c2"])
        XCTAssertEqual(detail.source, "com.apple.Safari")
        XCTAssertEqual(detail.text, "\n  first line\nsecond line")
        await model.loadDetail("c1")
        XCTAssertNil(model.details["c2"], "changing selection drops the preceding content")
        XCTAssertEqual(model.details["c1"]?.text, "hello")
    }

    func testAnEntryThatIsGoneIsAFailureNotAnEmptyPreview() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        model.setVisible(true)
        await model.load()
        await model.loadDetail("nope")
        XCTAssertNil(model.details["nope"])
        XCTAssertEqual(model.detailFailures["nope"], "clipboard item nope is gone or can no longer be opened")
    }

    func testHidingThePageDropsTheOpenedContent() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        model.setVisible(true)
        await model.load()
        await model.loadDetail("c1")
        XCTAssertNotNil(model.details["c1"])
        model.setVisible(false)
        XCTAssertTrue(model.details.isEmpty)
        // Content that arrives after the page went away is not kept.
        await model.loadDetail("c1")
        XCTAssertTrue(model.details.isEmpty)
    }

    func testTurningItOnIsAConfigureCallAndTheListFollows() async throws {
        let model = ClipboardModel(session: try await started())
        await model.load()
        await model.setEnabled(true)
        XCTAssertEqual(model.state.value?.settings.enabled, true)
        XCTAssertNil(model.failure)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(try requests().contains("\"method\":\"clipboard.configure\""))
        XCTAssertTrue(try requests().contains("\"enabled\":true"))
        await model.setEnabled(false)
        XCTAssertEqual(model.state.value?.settings.enabled, false)
    }

    func testPauseAndResumeAreTheRegisterCommands() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        await model.load()
        await model.setPaused(true)
        XCTAssertEqual(model.state.value?.settings.paused, true)
        XCTAssertEqual(model.state.value?.settings.isCapturing, false)
        XCTAssertTrue(try requests().contains("\"command\":\"clipboard.pause\""))
        await model.setPaused(false)
        XCTAssertEqual(model.state.value?.settings.paused, false)
        XCTAssertTrue(try requests().contains("\"command\":\"clipboard.resume\""))
    }

    func testDeleteAllUsesClearAndReportsTheCount() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        await model.load()
        await model.clearAll()
        XCTAssertEqual(model.state.value?.items, [])
        XCTAssertEqual(model.notice, "Deleted 2 entries.")
        XCTAssertTrue(try requests().contains("\"command\":\"clipboard.clear\""))
    }

    func testDeleteOneRemovesOnlyThatEntry() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        await model.load()
        await model.delete("c2")
        XCTAssertEqual(model.state.value?.items.map(\.id), ["c1"])
        await model.delete("c2")
        XCTAssertNotNil(model.failure, "deleting what is gone says so")
    }

    func testCopyBackAsksTheAgentToPutTheEntryOnThePasteboard() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        await model.load()
        await model.copyBack("c1")
        XCTAssertEqual(model.notice, "Copied back to the clipboard.")
        let text = try requests()
        XCTAssertTrue(text.contains("\"method\":\"clipboard.copy\""))
        XCTAssertTrue(text.contains("\"id\":\"c1\""))
    }

    func testExcludedAppsAreAddedRemovedAndValidated() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        await model.load()
        let added = await model.addExcludedApp(" com.example.Notes ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.state.value?.settings.excludedApps, ["com.1password.1password", "com.example.Notes"])
        let again = await model.addExcludedApp("COM.EXAMPLE.NOTES")
        XCTAssertFalse(again)
        XCTAssertEqual(model.failure, "That app is already excluded.")
        let invalid = await model.addExcludedApp("not a bundle id")
        XCTAssertFalse(invalid)
        await model.removeExcludedApp("com.1password.1password")
        XCTAssertEqual(model.state.value?.settings.excludedApps, ["com.example.Notes"])
        let configures = try requests().components(separatedBy: "clipboard.configure").count - 1
        XCTAssertEqual(configures, 2, "a refused name never reaches the agent")
    }

    func testBundleIdentifierShape() {
        for good in ["com.apple.Safari", "org.keepassxc.keepassxc", "a.b-c_d"] {
            XCTAssertTrue(ClipboardModel.isValidBundleID(good), good)
        }
        for bad in ["", "Safari", ".com", "com.", "com example.App", "com.exämple.App", "com/x.y"] {
            XCTAssertFalse(ClipboardModel.isValidBundleID(bad), bad)
        }
    }

    func testAnAgentWithoutTheHostIsNotOfferedAndNothingIsAsked() async throws {
        let model = ClipboardModel(session: try await started(noHost: true))
        XCTAssertFalse(model.isOffered)
        XCTAssertFalse(model.canCopyBack)
        await model.load()
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(try requests().contains("clipboard."))
    }

    func testAnOpenPageSeesANewStateWithoutARefresh() async throws {
        let session = try await started(fixtures: seeded())
        let model = ClipboardModel(session: session)
        model.setVisible(true)
        await model.load()
        XCTAssertEqual(model.state.value?.items.count, 2)
        try await Task.sleep(nanoseconds: 400_000_000) // the first status sample is recorded
        _ = await session.perform("clipboard.clear")
        _ = await session.perform("__tick")
        try await eventually("the list to follow the status") { model.state.value?.items.isEmpty == true }
    }

    func testAHiddenPageSubscribesToNothing() async throws {
        let model = ClipboardModel(session: try await started(fixtures: seeded()))
        model.setVisible(true)
        model.setVisible(false)
        await model.load()
        try await Task.sleep(nanoseconds: 300_000_000)
        let text = try requests()
        XCTAssertEqual(text.components(separatedBy: "\"method\":\"subscribe\"").count - 1,
                       text.components(separatedBy: "\"method\":\"unsubscribe\"").count - 1)
    }

    func testAFailingServiceShowsItsError() async throws {
        var fixtures = seeded()
        var clip = fixtures["__clipboard"] as! [String: Any]
        clip["last_error"] = "pasteboard unavailable"
        fixtures["__clipboard"] = clip
        let model = ClipboardModel(session: try await started(fixtures: fixtures))
        await model.load()
        XCTAssertEqual(model.state.value?.serviceError, "pasteboard unavailable")
    }

    // MARK: Finder

    private func bundle(plugIns: [String], appGroup: String?) throws -> Bundle {
        let app = directory.appendingPathComponent("Fake.app")
        let contents = app.appendingPathComponent("Contents")
        for name in plugIns {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("PlugIns/\(name)"), withIntermediateDirectories: true)
        }
        var info: [String: Any] = ["CFBundleIdentifier": "test.fake", "CFBundlePackageType": "APPL"]
        info["SymCockpitAppGroup"] = appGroup
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
    }

    func testTheExtensionsInTheBundleAreReportedAsFactAndTheirStateIsNotGuessed() async throws {
        let bundle = try bundle(plugIns: ["SymCockpitFinderSync.appex"], appGroup: nil)
        let model = FinderModel(session: try await started(), bundle: bundle)
        XCTAssertEqual(model.extensions.map(\.name), ["Finder Actions", "Quick Look"])
        XCTAssertEqual(model.extensions.map(\.isInBundle), [true, false])
        XCTAssertNil(model.jobsDirectory, "a build without an app group has no job folder")
    }

    func testFinderActionsAreTheJobVocabulary() {
        XCTAssertEqual(FinderAction.all.map(\.id), ["copy_path", "new_file", "open_in_terminal"])
    }

    func testTheJobFolderIsTheAppGroupContainersJobsDirectory() {
        let base = URL(fileURLWithPath: "/tmp/group-container")
        XCTAssertEqual(
            AgentSession.finderJobsDirectory(appGroup: "TEAM.group.x", container: { _ in base })?.path,
            "/tmp/group-container/jobs")
        XCTAssertNil(AgentSession.finderJobsDirectory(appGroup: "", container: { _ in base }))
        XCTAssertNil(AgentSession.finderJobsDirectory(appGroup: nil, container: { _ in base }))
        XCTAssertNil(AgentSession.finderJobsDirectory(appGroup: "TEAM.group.x", container: { _ in nil }))
    }

    func testTheAgentsJobCountsAreShown() async throws {
        let jobs: [String: Any] = ["directory": "/tmp/jobs", "succeeded": 3, "failed": 1, "rejected": 2]
        let model = FinderModel(session: try await started(fixtures: ["__finder_jobs": jobs]), bundle: .main)
        await model.load()
        let report = try XCTUnwrap(model.state.value)
        XCTAssertTrue(report.isReported)
        let status = try XCTUnwrap(report.status)
        XCTAssertEqual(status.directory, "/tmp/jobs")
        XCTAssertEqual(status.succeeded, 3)
        XCTAssertEqual(status.failed, 1)
        XCTAssertEqual(status.rejected, 2)
    }

    func testAnAgentWithoutAJobFolderSaysSo() async throws {
        let model = FinderModel(session: try await started(), bundle: .main)
        await model.load()
        XCTAssertEqual(model.state.value, FinderJobsReport(isReported: true, status: nil))
    }

    func testAnAgentWithoutServicesReportsNothingAboutJobs() async throws {
        let model = FinderModel(session: try await started(noHost: true), bundle: .main)
        await model.load()
        XCTAssertEqual(model.state.value, FinderJobsReport(isReported: false, status: nil))
        XCTAssertFalse(try requests().contains("\"method\":\"services\""))
    }
}

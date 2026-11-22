import XCTest
@testable import SymCockpitCore

/// `HistoryModel` and `ProfilesModel` against the fake agent: the four states a page
/// shows (loading, loaded, empty, failed) and nothing written outside the fake.
@MainActor
final class PageModelTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.log") }
    private var sessions: [AgentSession] = []

    private static var fixtureDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func started(fixtures: [String: Any]? = nil, start: Bool = true) async throws -> AgentSession {
        var fixturePath = Self.fixtureDirectory.appendingPathComponent("agent-fixtures.json")
        if let fixtures {
            fixturePath = directory.appendingPathComponent("fixtures.json")
            try JSONSerialization.data(withJSONObject: fixtures).write(to: fixturePath)
        }
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [Self.fixtureDirectory.appendingPathComponent("fake-agent.pl").path, "ok"],
            environment: ["FAKE_AGENT_FIXTURES": fixturePath.path, "FAKE_AGENT_LOG": log.path],
            startTimeout: 10, requestTimeout: 5
        ))
        sessions.append(session)
        if start { await session.start() }
        return session
    }

    // MARK: History

    func testTheHistoryComesFromTheAgentNewestFirst() async throws {
        let model = HistoryModel(session: try await started())
        XCTAssertEqual(model.state, .idle)
        await model.load()
        let entries = try XCTUnwrap(model.state.value)
        XCTAssertEqual(entries.map(\.action), ["warmth.set", "fan.profile", "brightness.set"])
        XCTAssertEqual(entries.map(\.isSuccess), [true, false, true])
        XCTAssertEqual(entries[2].appliedValue, 0.5)
        XCTAssertEqual(entries[1].errorReason, "permission error: the fan helper is not approved")
        XCTAssertEqual(entries[2].date, Date(timeIntervalSinceReferenceDate: 785_000_000))
        XCTAssertEqual(Set(entries.map(\.id)).count, 3, "every row has its own identity")
    }

    func testTheHistoryAsksForItsLimit() async throws {
        let model = HistoryModel(session: try await started(), limit: 25)
        await model.load()
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("\"command\":\"history\""))
        XCTAssertTrue(text.contains("\"limit\":25"))
    }

    func testAnEmptyHistoryIsLoadedAndEmptyNotAnError() async throws {
        let model = HistoryModel(session: try await started(fixtures: ["history": []]))
        await model.load()
        XCTAssertEqual(model.state, .loaded([]))
    }

    func testAnAgentThatCannotAnswerGivesAFailureNotAnEmptyList() async throws {
        // The fake knows no `history` here: it answers "unknown command".
        let model = HistoryModel(session: try await started(fixtures: [:]))
        await model.load()
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure: \(model.state)") }
        XCTAssertTrue(message.contains("history"))
    }

    func testAnAgentThatIsNotRunningGivesAFailure() async throws {
        let model = HistoryModel(session: try await started(start: false))
        await model.load()
        guard case .failed = model.state else { return XCTFail("expected a failure: \(model.state)") }
    }

    func testAnUnreadableHistoryIsAFailure() async throws {
        let model = HistoryModel(session: try await started(fixtures: ["history": ["x"]]))
        await model.load()
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure: \(model.state)") }
        XCTAssertTrue(message.hasPrefix("The history could not be read"))
    }

    // MARK: Profiles

    func testTheProfilesAreListedByName() async throws {
        let model = ProfilesModel(session: try await started())
        await model.load()
        let profiles = try XCTUnwrap(model.state.value)
        XCTAssertEqual(profiles.map(\.name), ["day", "reading"])
        XCTAssertEqual(profiles[1].warmth, 0.6)
        XCTAssertNil(profiles[0].warmth)
    }

    func testApplyingAProfileSendsItsNameAndTellsTheHost() async throws {
        var changed = 0
        let model = ProfilesModel(session: try await started(), didChangeDisplay: { changed += 1 })
        await model.apply("reading")
        XCTAssertEqual(model.notice, "Applied “reading”.")
        XCTAssertNil(model.failure)
        XCTAssertEqual(changed, 1)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("\"command\":\"profile.load\""))
        XCTAssertTrue(text.contains("\"name\":\"reading\""))
    }

    func testSavingAndDeletingReloadTheList() async throws {
        let model = ProfilesModel(session: try await started())
        await model.load()
        await model.save("evening")
        XCTAssertEqual(model.state.value?.map(\.name), ["day", "evening", "reading"])
        await model.delete("day")
        XCTAssertEqual(model.state.value?.map(\.name), ["evening", "reading"])
        XCTAssertEqual(model.notice, "Deleted “day”.")
    }

    func testAnInvalidNameIsRefusedWithoutAskingTheAgent() async throws {
        let model = ProfilesModel(session: try await started())
        await model.save("../etc")
        XCTAssertNotNil(model.failure)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("profile.save"))
    }

    func testAFailedApplyShowsTheAgentsMessage() async throws {
        let model = ProfilesModel(session: try await started(start: false))
        await model.apply("reading")
        XCTAssertNil(model.notice)
        XCTAssertNotNil(model.failure)
    }
}

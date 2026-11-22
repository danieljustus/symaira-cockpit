import XCTest
@testable import SymCockpitCore

/// The shared plan confirmation (`PlanConfirmationModel`, `AgentSession.confirmReport`)
/// against the fake agent (Fixtures/fake-agent.pl). No Rust binary, hardware or
/// permission is involved; `fan.profile` and `battery-limit.set` are plans there.
@MainActor
final class PlanConfirmationTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("requests.log") }
    private var sessions: [AgentSession] = []

    private static var fixtureDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-confirmation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func started(_ scenario: String = "ok") async -> AgentSession {
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [Self.fixtureDirectory.appendingPathComponent("fake-agent.pl").path, scenario],
            environment: [
                "FAKE_AGENT_FIXTURES": Self.fixtureDirectory.appendingPathComponent("agent-fixtures.json").path,
                "FAKE_AGENT_LOG": log.path,
            ],
            startTimeout: 10, requestTimeout: 5
        ))
        sessions.append(session)
        await session.start()
        return session
    }

    private func plan(_ session: AgentSession, _ command: String = "fan.profile",
                      _ params: [String: AgentJSON] = ["profile": .string("comfort")]) async throws -> AgentPlan {
        guard case .needsConfirmation(let plan) = await session.perform(command, params: params) else {
            throw XCTSkip("\(command) did not return a plan")
        }
        return plan
    }

    private func requests(_ method: String) -> Int {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { $0.contains("\"method\":\"\(method)\"") }.count
    }

    // MARK: Plan

    func testAPlanCarriesItsCommandItemsAndExpiry() async throws {
        let session = await started()
        let before = Date()
        let plan = try await plan(session)
        XCTAssertEqual(plan.command, "fan.profile")
        XCTAssertEqual(plan.items.map(\.target), ["fan.profile"])
        XCTAssertNil(plan.items.first?.sizeBytes)
        XCTAssertEqual(plan.expiresInSeconds, 300)
        let expiry = try XCTUnwrap(plan.expiresAt)
        XCTAssertGreaterThanOrEqual(expiry, before.addingTimeInterval(300))
        XCTAssertLessThan(expiry, Date().addingTimeInterval(301))
    }

    func testAnItemNamesItsSizeWhenThePlanKnowsIt() {
        let json = AgentJSON.object([
            "expires_in_s": .number(60),
            "items": .array([
                .object(["target": .string("/tmp/a"), "bytes": .number(2048)]),
                .object(["target": .string("/tmp/b"), "size": .number(7)]),
                .object(["target": .string("/tmp/c")]),
            ]),
        ])
        let plan = AgentPlan(command: "plan_clean", planID: "pl_x", plan: json)
        XCTAssertEqual(plan.items.map(\.sizeBytes), [2048, 7, nil])
        XCTAssertEqual(plan.items.map(\.target), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    // MARK: Confirm

    func testNothingIsSentBeforeTheUserConfirms() async throws {
        let session = await started()
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(requests("confirm"), 0)
    }

    func testConfirmingReportsEveryItem() async throws {
        let session = await started()
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        var seen: PlanReport?
        model.onFinished = { seen = $0 }
        let report = await model.confirm()
        XCTAssertEqual(report?.status, .confirmed)
        XCTAssertEqual(report?.items.map(\.outcome), [.confirmed])
        XCTAssertEqual(report?.items.first?.target, "fan.profile")
        XCTAssertEqual(model.phase, .finished(try XCTUnwrap(report)))
        XCTAssertEqual(seen, report)
        XCTAssertEqual(requests("confirm"), 1)
    }

    func testAPlanIsSentAtMostOnce() async throws {
        let session = await started()
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        _ = await model.confirm()
        let again = await model.confirm()
        XCTAssertNil(again)
        XCTAssertEqual(requests("confirm"), 1)
    }

    func testMixedOutcomesAreReportedPerItemInTheAgentsWords() async throws {
        let session = await started("confirm_mixed")
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        let confirmed = await model.confirm()
        let report = try XCTUnwrap(confirmed)
        XCTAssertEqual(report.status, .failed)
        XCTAssertFalse(report.isConfirmed)
        XCTAssertEqual(report.items.map(\.outcome), [.confirmed, .skippedChanged, .failed])
        XCTAssertEqual(report.items.map(\.index), [0, 1, 2])
        XCTAssertEqual(report.items[1].detail, "the item changed after planning")
        XCTAssertEqual(report.items.map(\.outcome.label),
                       ["Done", "Skipped, changed since planning", "Failed"])
    }

    func testTheReportHasAHeadlineAndAnExplanation() async throws {
        let mixedSession = await started("confirm_mixed")
        let mixed = PlanConfirmationModel(plan: try await plan(mixedSession), session: mixedSession)
        let mixedReport = await mixed.confirm()
        XCTAssertEqual(mixedReport?.headline, "Partly applied")
        XCTAssertEqual(mixedReport?.explanation, "1 of 3 entries applied.")

        let deniedSession = await started("confirm_denied")
        let denied = PlanConfirmationModel(plan: try await plan(deniedSession), session: deniedSession)
        let deniedReport = await denied.confirm()
        XCTAssertEqual(deniedReport?.headline, "Not applied")
        XCTAssertTrue(deniedReport?.explanation.contains("fan helper is not approved") ?? false)

        let okSession = await started()
        let ok = PlanConfirmationModel(plan: try await plan(okSession), session: okSession)
        let okReport = await ok.confirm()
        XCTAssertEqual(okReport?.headline, "Applied")
    }

    func testADeniedPlanReportsTheReasonAndItsClass() async throws {
        let session = await started("confirm_denied")
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        let confirmed = await model.confirm()
        let report = try XCTUnwrap(confirmed)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.exitClass, "permission")
        XCTAssertTrue(report.failureMessage?.contains("fan helper is not approved") ?? false)
    }

    func testARefusalByTheAgentIsAFailedReportNotAThrownError() async throws {
        let session = await started("confirm_expired")
        let model = PlanConfirmationModel(plan: try await plan(session), session: session)
        let confirmed = await model.confirm()
        let report = try XCTUnwrap(confirmed)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.exitClass, "usage")
        XCTAssertTrue(report.failureMessage?.contains("expired") ?? false)
    }

    // MARK: Expiry

    func testAnExpiredPlanIsNotSentAndSaysSo() async throws {
        let session = await started()
        let plan = try await plan(session)
        let late = Date().addingTimeInterval(301)
        let model = PlanConfirmationModel(plan: plan, session: session, now: { late })
        XCTAssertEqual(model.secondsRemaining(), 0)
        XCTAssertTrue(model.isExpired())
        let confirmed = await model.confirm()
        let report = try XCTUnwrap(confirmed)
        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(report.failureMessage?.contains("expired") ?? false)
        XCTAssertEqual(requests("confirm"), 0, "an expired plan never reaches the agent")
    }

    func testTheRemainingTimeCountsDownToTheExpiry() async throws {
        let session = await started()
        let plan = try await plan(session)
        let model = PlanConfirmationModel(plan: plan, session: session)
        let start = try XCTUnwrap(plan.expiresAt).addingTimeInterval(-300)
        XCTAssertEqual(model.secondsRemaining(at: start), 300)
        XCTAssertEqual(model.secondsRemaining(at: start.addingTimeInterval(299.2)), 1)
        XCTAssertEqual(model.secondsRemaining(at: start.addingTimeInterval(400)), 0)
        XCTAssertFalse(model.isExpired(at: start.addingTimeInterval(299)))
    }

    // MARK: Compatibility

    func testConfirmStillReturnsTheActionOutcomeOfTheOlderCallers() async throws {
        let session = await started()
        guard case .done = await session.confirm(try await plan(session)) else {
            return XCTFail("a confirmed plan is done")
        }
        let denied = await started("confirm_denied")
        guard case .failed(let message, let exitClass) = await denied.confirm(try await plan(denied)) else {
            return XCTFail("a denied plan failed")
        }
        XCTAssertEqual(exitClass, "permission")
        XCTAssertTrue(message.contains("fan helper is not approved"))
    }
}

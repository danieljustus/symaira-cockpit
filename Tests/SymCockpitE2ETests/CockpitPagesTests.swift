import SwiftUI
@testable import SymCockpitCore
import SymairaTheme
import XCTest
@testable import SymCockpitUI

/// The pure parts of the window's pages: destinations, the agent status line, the
/// plan view's formatting and the rows of the history and profile cards. The
/// logic behind them (plan confirmation, history, profiles) is tested in
/// SymCockpitCoreTests against the fake agent.
@MainActor
final class CockpitPagesTests: XCTestCase {
    func testTheSidebarHasTheElevenDestinationsInOrder() {
        XCTAssertEqual(CockpitDestination.allCases.map(\.title), [
            "Overview", "Display", "Power & Fans", "Storage", "Audio & MIDI", "Bluetooth & Input",
            "Processes", "Clipboard", "Finder", "AI Usage", "History",
        ])
        XCTAssertEqual(Set(CockpitDestination.allCases.map(\.id)).count, 11)
    }

    func testTheFirstNineDestinationsHaveCommandDigits() {
        XCTAssertEqual(CockpitDestination.allCases.compactMap(\.shortcutDigit).map(String.init), (1...9).map(String.init))
        XCTAssertNil(CockpitDestination.aiUsage.shortcutDigit)
        XCTAssertNil(CockpitDestination.history.shortcutDigit)
    }

    func testEveryDestinationHasASubtitleOfOneLine() {
        for destination in CockpitDestination.allCases {
            XCTAssertFalse(destination.subtitle.isEmpty, destination.title)
            XCTAssertFalse(destination.subtitle.contains("\n"), destination.title)
        }
    }

    func testTheAgentStateBecomesAPhaseTheShellCanShow() {
        XCTAssertEqual(CockpitAgentStatus.phase(for: .stopped), .starting)
        XCTAssertEqual(CockpitAgentStatus.phase(for: .starting), .starting)
        guard case .failed(let diagnosis) = CockpitAgentStatus.phase(for: .failed(.exited(status: 3, stderr: "x"))) else {
            return XCTFail("a failed agent is a diagnosis")
        }
        XCTAssertEqual(diagnosis.title, "Cockpit agent refused to start")
    }

    func testTheSidebarStatusLineNamesEveryPhase() {
        let starting = CockpitWorkspaceView<EmptyView>.status(.starting)
        let ready = CockpitWorkspaceView<EmptyView>.status(.ready(version: "1"))
        let failed = CockpitWorkspaceView<EmptyView>.status(.failed(AgentDiagnosis(title: "t", detail: "d")))
        XCTAssertEqual([starting.0, ready.0, failed.0], ["Agent starting…", "Agent connected", "Agent not reachable"])
    }

    func testPlanOutcomesGetPlainWordsAndATone() {
        let words = [PlanOutcome.confirmed, .unconfirmed, .skippedChanged, .failed, .unsupported].map(\.label)
        XCTAssertEqual(words, ["Done", "Not verified", "Skipped, changed since planning", "Failed", "Not supported"])
        XCTAssertEqual(PlanConfirmationView.tone(.confirmed), .positive)
        XCTAssertEqual(PlanConfirmationView.tone(.skippedChanged), .warning)
        XCTAssertEqual(PlanConfirmationView.tone(.failed), .critical)
    }

    func testThePlanViewFormatsSizesAndTheCountdown() {
        XCTAssertEqual(PlanConfirmationView.clock(300), "5:00")
        XCTAssertEqual(PlanConfirmationView.clock(61), "1:01")
        XCTAssertEqual(PlanConfirmationView.clock(9), "0:09")
        XCTAssertTrue(PlanConfirmationView.size(2_048).contains("KB"))
        let plan = AgentPlan(command: "plan_clean", planID: "p", plan: .object([
            "items": .array([.object(["bytes": .number(1000)]), .object(["bytes": .number(500)]), .object([:])]),
        ]))
        XCTAssertEqual(PlanConfirmationView.total(plan.items), 1500)
        XCTAssertNil(PlanConfirmationView.total(AgentPlan(command: "c", planID: "p", plan: .object([:])).items))
    }

    func testAHistoryRowShowsWhatWasAppliedOrAskedAndNeverInventsAValue() {
        func entry(applied: Double?, requested: Double?) -> HistoryEntry {
            HistoryEntry(
                id: 0, action: "brightness.set", result: "success", date: Date(timeIntervalSinceReferenceDate: 0),
                requestedValue: requested, clampedValue: nil, appliedValue: applied, errorReason: nil
            )
        }
        XCTAssertEqual(HistoryPage.value(entry(applied: 0.5, requested: 0.9)), "0.50")
        XCTAssertEqual(HistoryPage.value(entry(applied: nil, requested: 0.9)), "0.90")
        XCTAssertEqual(HistoryPage.value(entry(applied: nil, requested: nil)), "—")
    }

    func testAProfileRowListsOnlyWhatTheProfileHolds() throws {
        let both = try TuneProfile(name: "reading", brightness: 0.4, dim: 0.8, warmth: 0.6)
        XCTAssertEqual(ProfilesCard.summary(both), "Brightness 40 % · Dimming 20 % · Warmth 60 %")
        XCTAssertEqual(ProfilesCard.summary(try TuneProfile(name: "day", brightness: 0.9)), "Brightness 90 %")
        XCTAssertEqual(ProfilesCard.summary(try TuneProfile(name: "empty")), "No display values")
    }
}

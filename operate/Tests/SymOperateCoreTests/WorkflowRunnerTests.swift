import XCTest
@testable import SymOperateCore

private actor WorkflowCallLog {
    private(set) var stepIDs: [String] = []

    func append(stepID: String) {
        stepIDs.append(stepID)
    }
}

private final class WorkflowHistoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [WorkflowHistoryEvent] = []

    func append(_ event: WorkflowHistoryEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    var events: [WorkflowHistoryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

private func confirmedWorkflowResult() -> ActionResult {
    ActionResult(
        ok: true,
        message: "confirmed",
        effect: .confirmed,
        verification: ActionVerification(
            status: .confirmed,
            strategy: "test",
            checkedAt: nil
        )
    )
}

final class WorkflowRunnerTests: XCTestCase {
    private let condition = ActionConditions(
        postcondition: UIElementPredicate(label: "Ready")
    )

    func testConfirmedStepsRunInOrderAndAggregateDeterministically() async {
        let log = WorkflowCallLog()
        let condition = self.condition
        let plan = WorkflowPlan(id: "ordered", steps: [
            WorkflowStep(id: "first", action: "click", conditions: condition),
            WorkflowStep(id: "second", action: "wait_for", conditions: condition),
            WorkflowStep(id: "third", action: "type_text", conditions: condition),
        ])
        let runner = WorkflowRunner(executor: { step in
            await log.append(stepID: step.id)
            return confirmedWorkflowResult()
        })

        let result = await runner.run(plan)

        let calls = await log.stepIDs
        XCTAssertEqual(calls, ["first", "second", "third"])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.steps.map(\.stepID), ["first", "second", "third"])
        XCTAssertTrue(result.steps.allSatisfy { $0.status == .completed })
        XCTAssertEqual(result.completedStepCount, 3)
    }

    func testUnverifiableStepAbortsAndSkipsRemainingSteps() async {
        let log = WorkflowCallLog()
        let condition = self.condition
        let plan = WorkflowPlan(id: "abort", steps: [
            WorkflowStep(id: "before", action: "click", conditions: condition),
            WorkflowStep(id: "unsafe", action: "type_text", conditions: condition),
            WorkflowStep(id: "after", action: "press_keys", conditions: condition),
        ])
        let runner = WorkflowRunner(executor: { step in
            await log.append(stepID: step.id)
            if step.id == "unsafe" {
                return ActionResult(
                    ok: true,
                    message: "submitted",
                    effect: .unverifiable,
                    verification: ActionVerification(status: .unverifiable, strategy: "test", checkedAt: nil)
                )
            }
            return confirmedWorkflowResult()
        })

        let result = await runner.run(plan)

        let calls = await log.stepIDs
        XCTAssertEqual(calls, ["before", "unsafe"])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureStepID, "unsafe")
        XCTAssertEqual(result.steps.map(\.status), [.completed, .failed, .skipped])
    }

    func testMaximumStepBoundAndHistoryHookRedactSensitiveParameters() async {
        let history = WorkflowHistoryBox()
        let condition = self.condition
        let steps = (0..<WorkflowPlan.maxSteps + 1).map { index in
            WorkflowStep(
                id: "step-\(index)",
                action: "type_text",
                parameters: ["text": "my-secret-password"],
                conditions: condition
            )
        }
        let plan = WorkflowPlan(id: "bounded", steps: steps)
        let runner = WorkflowRunner(
            executor: { _ in XCTFail("An over-bound plan must not execute"); return confirmedWorkflowResult() },
            history: { event in history.append(event) }
        )

        let result = await runner.run(plan)

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.steps.count, WorkflowPlan.maxSteps + 1)
        XCTAssertTrue(result.steps.allSatisfy { $0.status == .skipped })
        let events = history.events
        XCTAssertEqual(events.count, WorkflowPlan.maxSteps + 1)
        XCTAssertEqual(events[0].parameters["text"], "<redacted>")
        XCTAssertFalse(events[0].parameters.values.contains("my-secret-password"))
    }
}

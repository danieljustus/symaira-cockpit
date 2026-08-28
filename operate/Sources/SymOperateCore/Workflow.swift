import Foundation

/// The terminal state of a workflow run.
public enum WorkflowRunStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
    case invalid
}

/// The terminal state recorded for each ordered workflow step.
public enum WorkflowStepStatus: String, Codable, Sendable {
    case completed
    case failed
    case skipped
    case cancelled
}

/// One action in a verified workflow. Conditions are kept on the step so the
/// executor can pass them directly to the existing AutomationController APIs.
public struct WorkflowStep: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let action: String
    public let parameters: [String: String]
    public let conditions: ActionConditions

    public init(
        id: String,
        action: String,
        parameters: [String: String] = [:],
        conditions: ActionConditions = ActionConditions()
    ) {
        self.id = id
        self.action = action
        self.parameters = parameters
        self.conditions = conditions
    }

    public init(
        id: String,
        action: String,
        parameters: [String: String] = [:],
        precondition: UIElementPredicate? = nil,
        postcondition: UIElementPredicate? = nil
    ) {
        self.init(
            id: id,
            action: action,
            parameters: parameters,
            conditions: ActionConditions(precondition: precondition, postcondition: postcondition)
        )
    }
}

/// An ordered, deliberately bounded workflow plan.
public struct WorkflowPlan: Codable, Sendable, Equatable {
    public static let maxSteps = 32

    public let id: String
    public let steps: [WorkflowStep]

    public init(id: String = "workflow", steps: [WorkflowStep]) {
        self.id = id
        self.steps = steps
    }

    public var isWithinBound: Bool {
        steps.count <= Self.maxSteps
    }
}

/// A redacted event emitted after each attempted or skipped step.
public struct WorkflowHistoryEvent: Codable, Sendable, Equatable {
    public let planID: String
    public let stepID: String
    public let action: String
    public let status: WorkflowStepStatus
    public let parameters: [String: String]
    public let message: String

    public init(
        planID: String,
        stepID: String,
        action: String,
        status: WorkflowStepStatus,
        parameters: [String: String] = [:],
        message: String
    ) {
        let redactedParameters = Self.redact(parameters)
        self.planID = planID
        self.stepID = stepID
        self.action = action
        self.status = status
        self.parameters = redactedParameters
        self.message = Self.redact(message, sensitiveValues: parameters.compactMap { key, value in
            Self.isSensitiveKey(key) ? value : nil
        })
    }

    private static let sensitiveKeyFragments = [
        "password", "secret", "token", "credential", "authorization", "api_key", "apikey", "text"
    ]

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func redact(_ parameters: [String: String]) -> [String: String] {
        parameters.reduce(into: [:]) { result, entry in
            result[entry.key] = isSensitiveKey(entry.key) ? "<redacted>" : entry.value
        }
    }

    private static func redact(_ message: String, sensitiveValues: [String]) -> String {
        sensitiveValues.reduce(message) { value, secret in
            guard !secret.isEmpty else { return value }
            return value.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }
}

public typealias WorkflowHistoryHook = @Sendable (WorkflowHistoryEvent) -> Void

/// The result of one step, retained in plan order for deterministic aggregation.
public struct WorkflowStepResult: Codable, Sendable {
    public let stepID: String
    public let action: String
    public let status: WorkflowStepStatus
    public let result: ActionResult?
    public let message: String?

    public init(
        stepID: String,
        action: String,
        status: WorkflowStepStatus,
        result: ActionResult? = nil,
        message: String? = nil
    ) {
        self.stepID = stepID
        self.action = action
        self.status = status
        self.result = result
        self.message = message
    }
}

/// Deterministically aggregates the completed prefix and the skipped suffix.
public struct WorkflowResult: Codable, Sendable {
    public let planID: String
    public let status: WorkflowRunStatus
    public let steps: [WorkflowStepResult]
    public let failureStepID: String?
    public let message: String?

    public init(
        planID: String,
        status: WorkflowRunStatus,
        steps: [WorkflowStepResult],
        failureStepID: String? = nil,
        message: String? = nil
    ) {
        self.planID = planID
        self.status = status
        self.steps = steps
        self.failureStepID = failureStepID
        self.message = message
    }

    public var completedStepCount: Int {
        steps.lazy.filter { $0.status == .completed }.count
    }
}

/// Runs a plan serially. A step must return a confirmed ActionResult before
/// the next step starts; failures, unverifiable results, and cancellation abort
/// the remaining suffix.
public struct WorkflowRunner: Sendable {
    public typealias Executor = @Sendable (WorkflowStep) async throws -> ActionResult

    private let executor: Executor
    private let history: WorkflowHistoryHook?

    public init(executor: @escaping Executor, history: WorkflowHistoryHook? = nil) {
        self.executor = executor
        self.history = history
    }

    public func run(_ plan: WorkflowPlan) async -> WorkflowResult {
        guard plan.isWithinBound else {
            let message = "Workflow exceeds the maximum of \(WorkflowPlan.maxSteps) steps."
            let skipped = plan.steps.map { step in
                let result = WorkflowStepResult(
                    stepID: step.id,
                    action: step.action,
                    status: .skipped,
                    message: message
                )
                emit(planID: plan.id, step: step, status: .skipped, message: message)
                return result
            }
            return WorkflowResult(planID: plan.id, status: .invalid, steps: skipped, message: message)
        }

        guard plan.steps.allSatisfy({ $0.conditions.precondition != nil || $0.conditions.postcondition != nil }) else {
            let message = "Every workflow step must declare a precondition or postcondition."
            let skipped = plan.steps.map { step in
                let result = WorkflowStepResult(
                    stepID: step.id,
                    action: step.action,
                    status: .skipped,
                    message: message
                )
                emit(planID: plan.id, step: step, status: .skipped, message: message)
                return result
            }
            return WorkflowResult(planID: plan.id, status: .invalid, steps: skipped, message: message)
        }

        var stepResults: [WorkflowStepResult] = []
        stepResults.reserveCapacity(plan.steps.count)

        for (index, step) in plan.steps.enumerated() {
            if Task.isCancelled {
                return abort(
                    plan: plan,
                    results: &stepResults,
                    nextIndex: index,
                    status: .cancelled,
                    message: "Workflow was cancelled."
                )
            }

            do {
                let actionResult = try await executor(step)
                guard actionResult.ok,
                      actionResult.effect == .confirmed,
                      actionResult.verification.status == .confirmed else {
                    let message = "Step did not produce a confirmed, verifiable result."
                    let stepResult = WorkflowStepResult(
                        stepID: step.id,
                        action: step.action,
                        status: .failed,
                        result: actionResult,
                        message: message
                    )
                    stepResults.append(stepResult)
                    emit(planID: plan.id, step: step, status: .failed, message: message)
                    return abort(
                        plan: plan,
                        results: &stepResults,
                        nextIndex: index + 1,
                        status: .failed,
                        failureStepID: step.id,
                        message: message
                    )
                }

                let stepResult = WorkflowStepResult(
                    stepID: step.id,
                    action: step.action,
                    status: .completed,
                    result: actionResult
                )
                stepResults.append(stepResult)
                emit(planID: plan.id, step: step, status: .completed, message: "Step completed.")
            } catch is CancellationError {
                let message = "Workflow was cancelled."
                stepResults.append(WorkflowStepResult(stepID: step.id, action: step.action, status: .cancelled, message: message))
                emit(planID: plan.id, step: step, status: .cancelled, message: message)
                return abort(
                    plan: plan,
                    results: &stepResults,
                    nextIndex: index + 1,
                    status: .cancelled,
                    failureStepID: step.id,
                    message: message
                )
            } catch {
                let message = error.localizedDescription
                stepResults.append(WorkflowStepResult(stepID: step.id, action: step.action, status: .failed, message: message))
                emit(planID: plan.id, step: step, status: .failed, message: message)
                return abort(
                    plan: plan,
                    results: &stepResults,
                    nextIndex: index + 1,
                    status: .failed,
                    failureStepID: step.id,
                    message: message
                )
            }
        }

        return WorkflowResult(planID: plan.id, status: .completed, steps: stepResults)
    }

    private func abort(
        plan: WorkflowPlan,
        results: inout [WorkflowStepResult],
        nextIndex: Int,
        status: WorkflowRunStatus,
        failureStepID: String? = nil,
        message: String
    ) -> WorkflowResult {
        for step in plan.steps.dropFirst(nextIndex) {
            results.append(WorkflowStepResult(stepID: step.id, action: step.action, status: .skipped, message: "Skipped after workflow abort."))
            emit(planID: plan.id, step: step, status: .skipped, message: "Skipped after workflow abort.")
        }
        return WorkflowResult(planID: plan.id, status: status, steps: results, failureStepID: failureStepID, message: message)
    }

    private func emit(planID: String, step: WorkflowStep, status: WorkflowStepStatus, message: String) {
        history?(WorkflowHistoryEvent(
            planID: planID,
            stepID: step.id,
            action: step.action,
            status: status,
            parameters: step.parameters,
            message: message
        ))
    }
}

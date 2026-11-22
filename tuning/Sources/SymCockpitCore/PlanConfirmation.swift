import Foundation
import Observation

// What the app shows around a plan of a risky command (docs/agent-protocol.md,
// `confirm`): the model of the one shared confirmation, and the report it ends
// with. The plan engine of the agent decides everything (what is checked again,
// what counts as confirmed); this file only carries its answer to the view.

// MARK: - Report

/// How one item, or the whole plan, ended. The agent's words, as named in the plan report.
public enum PlanOutcome: Equatable, Sendable {
    case confirmed
    /// Ran, but the readback did not show the expected state.
    case unconfirmed
    /// The target changed after the plan was recorded, so nothing was done to it.
    case skippedChanged
    case failed
    case unsupported
    /// A word this app does not know yet; shown as it came.
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "confirmed": self = .confirmed
        case "unconfirmed": self = .unconfirmed
        case "skipped_changed": self = .skippedChanged
        case "failed": self = .failed
        case "unsupported": self = .unsupported
        case let other?: self = .other(other)
        case nil: self = .other("unknown")
        }
    }

    public var rawValue: String {
        switch self {
        case .confirmed: "confirmed"
        case .unconfirmed: "unconfirmed"
        case .skippedChanged: "skipped_changed"
        case .failed: "failed"
        case .unsupported: "unsupported"
        case .other(let word): word
        }
    }

    /// Plain words for the person looking at the result.
    public var label: String {
        switch self {
        case .confirmed: "Done"
        case .unconfirmed: "Not verified"
        case .skippedChanged: "Skipped, changed since planning"
        case .failed: "Failed"
        case .unsupported: "Not supported"
        case .other(let word): word
        }
    }
}

/// The result of one plan item.
public struct PlanItemResult: Equatable, Sendable, Identifiable {
    public let index: Int
    public let action: String
    public let target: String
    public let outcome: PlanOutcome
    public let detail: String?

    public var id: Int { index }
}

/// What `confirm` answered, or why it could not.
public struct PlanReport: Equatable, Sendable {
    public let planID: String
    public let status: PlanOutcome
    public let items: [PlanItemResult]
    /// The command's own output, when it ran and succeeded.
    public let output: AgentJSON?
    /// Why it did not apply: the agent's message, the transport's, or the plan's expiry.
    public let failureMessage: String?
    /// `usage`, `permission`, `unsupported` or `error` when the agent said so.
    public let exitClass: String?

    public var isConfirmed: Bool { status == .confirmed }

    init(planID: String, json: AgentJSON) {
        self.planID = planID
        self.status = PlanOutcome(json["status"]?.stringValue)
        self.items = (json["results"]?.arrayValue ?? []).enumerated().map { offset, entry in
            PlanItemResult(
                index: entry["index"]?.intValue ?? offset,
                action: entry["action"]?.stringValue ?? "",
                target: entry["target"]?.stringValue ?? "",
                outcome: PlanOutcome(entry["outcome"]?.stringValue),
                detail: entry["detail"]?.stringValue
            )
        }
        self.output = json["output"]
        self.failureMessage = json["error"]?["message"]?.stringValue
        self.exitClass = json["error"]?["data"]?["class"]?.stringValue
    }

    init(planID: String, failed message: String, exitClass: String?) {
        self.planID = planID
        self.status = .failed
        self.items = []
        self.output = nil
        self.failureMessage = message
        self.exitClass = exitClass
    }
}

extension AgentSession {
    /// Executes a plan the user approved and returns the report with one result per
    /// item. A rejection by the agent (unknown, expired or already used plan) or a
    /// broken transport is a `.failed` report with its message, never a thrown error.
    public func confirmReport(_ plan: AgentPlan) async -> PlanReport {
        do {
            return PlanReport(planID: plan.id, json: try await confirmRaw(planID: plan.id))
        } catch let remote as AgentRemoteError {
            return PlanReport(planID: plan.id, failed: remote.message, exitClass: remote.exitClass)
        } catch {
            return PlanReport(planID: plan.id, failed: error.localizedDescription, exitClass: nil)
        }
    }
}

// MARK: - Model

/// One plan on its way from "recorded, nothing happened yet" to the report.
///
/// The view shows `plan` while `reviewing`, offers Confirm and Cancel, and the
/// report once `finished`. The model refuses to send a plan that expired by its own
/// clock (the agent would refuse it anyway) and sends a plan at most once.
@MainActor
@Observable
public final class PlanConfirmationModel {
    public enum Phase: Equatable, Sendable {
        case reviewing
        case running
        case finished(PlanReport)
    }

    public let plan: AgentPlan
    public private(set) var phase = Phase.reviewing
    /// Called once with the report; the host refreshes what the plan changed.
    @ObservationIgnored public var onFinished: ((PlanReport) -> Void)?

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(plan: AgentPlan, session: AgentSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.plan = plan
        self.session = session
        self.now = now
    }

    public var report: PlanReport? {
        if case .finished(let report) = phase { return report }
        return nil
    }

    /// Whole seconds left to confirm, or `nil` when the agent named no expiry.
    public func secondsRemaining(at date: Date? = nil) -> Int? {
        plan.expiresAt.map { max(0, Int($0.timeIntervalSince(date ?? now()).rounded(.up))) }
    }

    public func isExpired(at date: Date? = nil) -> Bool {
        secondsRemaining(at: date) == 0
    }

    /// The user approved. Does nothing unless the plan is still waiting for that.
    @discardableResult
    public func confirm() async -> PlanReport? {
        guard phase == .reviewing else { return nil }
        let report: PlanReport
        if isExpired() {
            report = PlanReport(
                planID: plan.id,
                failed: "The plan expired before it was confirmed. Nothing was changed. Request the change again.",
                exitClass: nil
            )
        } else {
            phase = .running
            report = await session.confirmReport(plan)
        }
        phase = .finished(report)
        onFinished?(report)
        return report
    }
}

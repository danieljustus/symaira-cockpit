import Foundation
import Observation

/// Ending a process from the Processes page (`processes.kill`). The agent only records a plan (it
/// remembers the process's start time and path, so an id that another process took over is
/// skipped) and sends SIGTERM when the user confirms. This model asks for the plan and keeps what
/// the agent refused: a process the agent will not end (an id below the register's minimum, a
/// process of another user) shows as not endable, in the agent's words.
@MainActor
@Observable
public final class ProcessKillModel {
    public private(set) var confirmation: PlanConfirmationModel?
    /// The process a plan is being requested for.
    public private(set) var requesting: Int32?
    /// The last process the agent refused to plan, with its reason.
    private var lastRefusal: (pid: Int32, name: String, reason: String)?
    /// A failure that is not about one process (the agent is gone, the answer was not a plan).
    public private(set) var failure: String?
    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private let didFinish: @MainActor () -> Void

    /// `didFinish` runs after a confirmed plan ended, so the list reads again.
    public init(session: AgentSession, didFinish: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.didFinish = didFinish
    }

    /// The lowest process id the agent plans to end, from its register (`processes.kill` takes no pid below 2).
    public var minimumPID: Int { session.minimum(of: "pid", in: "processes.kill") ?? 2 }

    public var isAvailable: Bool {
        session.hello?.commands.contains { $0.name == "processes.kill" } == true
    }

    public func protection(for pid: Int32) -> String? {
        if Int(pid) < minimumPID { return "Protected system process (PID below \(minimumPID))." }
        if pid == session.processID { return "Protected Cockpit agent process." }
        return nil
    }

    public func refusal(for pid: Int32, name: String) -> String? {
        guard let lastRefusal, lastRefusal.pid == pid, lastRefusal.name == name else { return nil }
        return lastRefusal.reason
    }

    public func request(pid: Int32, name: String) async {
        guard confirmation == nil, requesting == nil, protection(for: pid) == nil else { return }
        requesting = pid
        failure = nil
        lastRefusal = nil
        defer { requesting = nil }
        switch await session.plan("processes.kill", params: ["pid": .number(Double(pid))]) {
        case .needsConfirmation(let plan):
            let model = PlanConfirmationModel(plan: plan, session: session)
            model.onFinished = { [weak self] _ in self?.didFinish() }
            confirmation = model
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            // The agent speaking about this process: not allowed, or no longer there.
            if exitClass == "permission" || exitClass == "usage" {
                lastRefusal = (pid, name, text)
            } else {
                failure = text
            }
        case .done:
            failure = "The Cockpit agent answered without a plan."
        }
    }

    public func close() {
        confirmation = nil
    }
}

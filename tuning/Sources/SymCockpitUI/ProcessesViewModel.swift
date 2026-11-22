import Foundation
import Observation
import SymCockpitCore

/// Shows the agent's `processes` samples for the popover's "Top Processes" card.
///
/// Kept separate from ``TuneViewModel`` because its lifetime is different: the
/// subscription exists only while the card is actually expanded *and* the
/// popover is open. A collapsed card costs nothing, which is the point — a
/// process sweep every couple of seconds is not something a menu-bar app
/// should do in the background forever.
@MainActor
@Observable
final class ProcessesViewModel {
    // MARK: - Published state

    private(set) var report: ProcessUsageReport = .empty
    private(set) var hasSample = false
    var selectedPID: Int32?
    /// `true` until the first sample with CPU rates arrives.
    private(set) var isWarmingUp = true
    /// `true` while an explicit, elevated GPU fetch is in flight (waiting on
    /// the administrator-password prompt, then on `powermetrics` itself).
    private(set) var isLoadingGPUUsage = false
    /// The agent's reason when it could not sample (not a value).
    private(set) var problem: String?

    /// Which resource the list is ranked by. Changing it asks the agent for the
    /// new ranking at once.
    var sortedBy: ProcessSortKey = .cpu {
        didSet {
            guard oldValue != sortedBy else { return }
            refreshNow()
        }
    }

    /// How many rows the card shows.
    var limit: Int = 6

    // MARK: - Dependencies

    private let session: AgentSession
    /// Sampling cadence while visible. One sample is two sweeps one second
    /// apart inside the agent, so this keeps the agent from being busy all the time.
    private static let interval = 3000
    private let owner: String

    private var token: UUID?
    private var isVisible = false
    private var lastSequence = 0
    private var subscriptionID: UUID?

    init(session: AgentSession, owner: String = "processes") {
        self.session = session
        self.owner = owner
    }

    // MARK: - Lifecycle

    /// Start or stop sampling. Idempotent.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            subscribe()
        } else {
            unsubscribe()
            // Drop the last sample: it goes stale the moment sampling stops, and a
            // stale reading shown without a timestamp is worse than none.
            report = .empty
            hasSample = false
            isWarmingUp = true
        }
        session.setVisible(visible, owner: owner)
    }

    /// Ask for the current ranking right now (after a sort change).
    func refreshNow() {
        guard isVisible else { return }
        unsubscribe()
        subscribe()
    }

    private func subscribe() {
        hasSample = false
        isWarmingUp = true
        problem = nil
        lastSequence = 0
        let id = UUID()
        subscriptionID = id
        token = session.subscribe(
            "processes",
            params: ["sort_by": .string(sortedBy.rawValue), "limit": .number(Double(limit))],
            visibleMs: Self.interval
        ) { [weak self] event in
            Task { @MainActor in
                guard let self, self.subscriptionID == id else { return }
                self.receive(event)
            }
        }
    }

    private func unsubscribe() {
        subscriptionID = nil
        if let token { session.unsubscribe(token) }
        token = nil
    }

    // MARK: - Receiving

    private func receive(_ event: AgentEvent) {
        guard event.sequence > lastSequence || event.sequence == 0 else { return }
        lastSequence = max(lastSequence, event.sequence)
        switch event.payload {
        case .result(let json):
            guard let fresh = try? AgentDecoding.decode(ProcessUsageReport.self, from: json) else {
                problem = "The agent's process list could not be read."
                return
            }
            problem = nil
            hasSample = true
            // The IORegistry GPU source can be empty without root: an already
            // showing GPU report is left alone rather than clobbered by it.
            if fresh.sortedBy == .gpu, fresh.processes.isEmpty, report.sortedBy == .gpu, !report.processes.isEmpty {
                return
            }
            if report != fresh { report = fresh }
            if isWarmingUp, fresh.processes.contains(where: { $0.cpuPercent != nil }) {
                isWarmingUp = false
            }
        case .error(let error):
            problem = error.message
        }
    }

    /// One-shot, explicitly user-triggered GPU sample, run as root via
    /// ``PrivilegedElevation``. Deliberately not part of the sampling:
    /// GPU sampling needs an administrator-password prompt, and popping that
    /// every couple of seconds would be unacceptable — this runs only when
    /// the person taps the button, once per tap.
    func loadGPUUsageWithElevation() {
        guard !isLoadingGPUUsage else { return }
        isLoadingGPUUsage = true
        let requestedLimit = limit

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> ProcessUsageReport in
                do {
                    let output = try PrivilegedElevation.runSymCockpit([
                        "processes", "--sort", "gpu", "--limit", "\(requestedLimit)", "--json",
                    ])
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    return try decoder.decode(ProcessUsageReport.self, from: output)
                } catch {
                    let message = (error as? PrivilegedElevation.ElevationError)?.description
                        ?? "Could not load GPU usage: \(error.localizedDescription)"
                    return ProcessUsageReport(
                        sortedBy: .gpu,
                        processes: [],
                        sampledProcessCount: 0,
                        unreadableProcessCount: 0,
                        notes: [message]
                    )
                }
            }.value

            isLoadingGPUUsage = false
            hasSample = true
            report = outcome
        }
    }
}

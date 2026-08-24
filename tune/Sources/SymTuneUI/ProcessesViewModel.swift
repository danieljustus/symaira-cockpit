import Foundation
import Observation
import SymTuneCore

/// Samples the process table for the popover's "Top Processes" card.
///
/// Kept separate from ``TuneViewModel`` because its lifetime is different: the
/// list only samples while the card is actually expanded *and* the popover is
/// open. A collapsed card costs nothing, which is the point — a process sweep
/// every couple of seconds is not something a menu-bar app should do in the
/// background forever.
@MainActor
@Observable
final class ProcessesViewModel {
    // MARK: - Published state

    private(set) var report: ProcessUsageReport = .empty
    /// `true` between the first sweep and the second, when no CPU rate exists.
    private(set) var isWarmingUp = true

    /// Which resource the list is ranked by. Changing it re-ranks immediately
    /// from the sample already in hand — no extra sweep.
    var sortedBy: ProcessSortKey = .cpu {
        didSet {
            guard oldValue != sortedBy else { return }
            refreshNow()
        }
    }

    /// How many rows the card shows.
    var limit: Int = 6

    // MARK: - Dependencies

    private let controller: TuneController
    /// Sampling cadence while visible. Fast enough to feel live, slow enough
    /// that the sweep itself (a few milliseconds) stays invisible.
    private static let interval: TimeInterval = 2.0

    private var pollTask: Task<Void, Never>?
    private var isVisible = false

    init(controller: TuneController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    /// Start or stop sampling. Idempotent.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        pollTask?.cancel()
        isWarmingUp = true
        // A stale baseline would make the first reading average CPU across the
        // whole time the card was closed.
        controller.resetProcessBaseline()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                do {
                    try await Task.sleep(for: .seconds(Self.interval))
                } catch {
                    return
                }
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        controller.resetProcessBaseline()
        // Drop the last sample: it goes stale the moment sampling stops, and a
        // stale reading shown without a timestamp is worse than none.
        report = .empty
        isWarmingUp = true
    }

    /// Re-rank right now (after a sort change), without waiting for the tick.
    func refreshNow() {
        guard isVisible else { return }
        Task { await sample() }
    }

    // MARK: - Sampling

    private func sample() async {
        let sort = sortedBy
        let limit = self.limit
        let controller = self.controller
        // libproc sweeps the whole process table; keep it off the main thread.
        let fresh = await Task.detached(priority: .utility) {
            controller.topProcesses(sortedBy: sort, limit: limit)
        }.value

        if report != fresh { report = fresh }
        if isWarmingUp, fresh.processes.contains(where: { $0.cpuPercent != nil }) {
            isWarmingUp = false
        }
    }
}

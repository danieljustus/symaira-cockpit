import Foundation
import Observation
import SymCockpitCore

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
    /// `true` while an explicit, elevated GPU fetch is in flight (waiting on
    /// the administrator-password prompt, then on `powermetrics` itself).
    private(set) var isLoadingGPUUsage = false

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
        if sort == .gpu {
            // The IORegistry source reads GPU time unprivileged, so poll it
            // like CPU/memory and show any rows it returns. Its absence
            // (powermetrics fallback, which needs root) comes back as an
            // empty report: then only the explicit
            // ``loadGPUUsageWithElevation()`` action populates real data, and
            // an already-showing GPU report is left alone rather than
            // clobbered every couple seconds by that empty one. A stale
            // non-GPU report is still cleared when the tab is first selected.
            let limit = self.limit
            let controller = self.controller
            let fresh = await Task.detached(priority: .utility) {
                controller.topProcesses(sortedBy: .gpu, limit: limit)
            }.value
            if !fresh.processes.isEmpty {
                if report != fresh { report = fresh }
            } else if report.sortedBy != .gpu {
                report = fresh
            }
            return
        }

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

    /// One-shot, explicitly user-triggered GPU sample, run as root via
    /// ``PrivilegedElevation``. Deliberately not part of the polling loop:
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
                        "tune", "processes", "--sort", "gpu", "--limit", "\(requestedLimit)", "--json",
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
            report = outcome
        }
    }
}

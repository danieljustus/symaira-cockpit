import Foundation
@testable import SymTuneCore

final class FakeSystemMetricsSource: SystemMetricsSource, @unchecked Sendable {
    private let snapshots: [SystemMetricsSnapshot]
    private let lock = NSLock()
    private var index = 0
    init(snapshots: [SystemMetricsSnapshot]) { self.snapshots = snapshots }

    func readSnapshot() -> SystemMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else { return .empty }
        let value = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return value
    }
}

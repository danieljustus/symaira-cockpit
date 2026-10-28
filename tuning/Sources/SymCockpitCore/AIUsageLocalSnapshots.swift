import Foundation

/// Main-actor GUI and CLI cache polling publish immutable rows here. HTTP
/// connections read memory only and can never trigger provider work.
public final class AIUsageLocalSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AIUsageService.ProviderResult] = []

    public init() {}

    public func replace(_ rows: [AIUsageService.ProviderResult]) {
        lock.withLock { self.rows = rows }
    }

    public func read() -> [AIUsageService.ProviderResult] {
        lock.withLock { rows }
    }
}

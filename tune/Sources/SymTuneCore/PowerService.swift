import Foundation
import IOKit.pwr_mgt

/// Opaque handle for an active keep-awake power assertion. Release it via
/// `PowerService.end(_:)` (or let the process exit — macOS releases assertions
/// held by a terminated process automatically).
public struct KeepAwakeToken: Sendable {
    let id: IOPMAssertionID
}

/// Wraps IOKit power-management assertions to prevent idle sleep. Fully
/// unprivileged — the analog of `/usr/bin/caffeinate`.
public struct PowerService: Sendable {
    private let source: any PowerAssertionSource

    public init(source: any PowerAssertionSource = HardwarePowerAssertionSource()) {
        self.source = source
    }

    public func begin(reason: String, preventDisplaySleep: Bool) throws -> KeepAwakeToken {
        let type: PowerAssertionType = preventDisplaySleep
            ? .preventDisplaySleep
            : .preventSystemSleep
        let id = try source.create(type: type, reason: reason)
        return KeepAwakeToken(id: IOPMAssertionID(id))
    }

    public func end(_ token: KeepAwakeToken) {
        source.release(UInt32(token.id))
    }
}

import Foundation
import Network
import os

/// Whether the Mac has a usable network path, so an offline Mac is not reported as
/// failing AI providers (#452). One shared path monitor, started on first use.
final class NetworkStatus: Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let online = OSAllocatedUnfairLock(initialState: true)

    private init() {
        monitor.pathUpdateHandler = { [online] path in
            online.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.symaira.cockpit.network-status"))
    }

    var isOnline: Bool { online.withLock { $0 } }
}

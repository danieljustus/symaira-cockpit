import Foundation
import IOKit
import IOKit.pwr_mgt

/// Wake observer for long-lived processes without an NSWorkspace notification
/// center (e.g. `symtune serve`). Registers with `IORegisterForSystemPower`
/// and invokes the callback on its own run-loop thread whenever the system
/// powers on — the point where volatile Apple Silicon SMC state (charge-limit
/// inhibit) is known to reset.
final class PowerWakeMonitor: @unchecked Sendable {
    /// `kIOMessageSystemHasPoweredOn` / `kIOMessageSystemWillPowerOn` are
    /// macros (`iokit_common_msg`) that Swift cannot import; these are their
    /// fully expanded values (`sys_iokit | sub_iokit_common | 0x300/0x320`).
    private static let messageSystemHasPoweredOn: UInt32 = 0x0E00_0300
    private static let messageSystemWillPowerOn: UInt32 = 0x0E00_0320

    private let onWake: () -> Void
    private let lock = NSLock()
    private var started = false
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private var runLoop: CFRunLoop?

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
    }

    /// Start listening for wake events. Idempotent; the monitor runs until
    /// the process exits (the run loop never returns by design).
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let monitor = self
        Thread.detachNewThread {
            monitor.runLoopBody()
        }
    }

    private func runLoopBody() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let connection = IORegisterForSystemPower(
            refcon, &port, Self.powerInterestCallback, &notifier
        )
        guard connection != 0, let port else {
            fputs("symtune: warning: failed to register for system power notifications\n", stderr)
            lock.lock()
            started = false
            lock.unlock()
            return
        }
        lock.lock()
        self.notificationPort = port
        self.notifier = notifier
        self.powerConnection = connection
        let loop = CFRunLoopGetCurrent()
        self.runLoop = loop
        lock.unlock()

        CFRunLoopAddSource(loop, IONotificationPortGetRunLoopSource(port)?.takeRetainedValue(), .defaultMode)
        CFRunLoopRun()
    }

    private static let powerInterestCallback: IOServiceInterestCallback = { _, _, messageType, refcon in
        guard let refcon else { return }
        if messageType == PowerWakeMonitor.messageSystemHasPoweredOn
            || messageType == PowerWakeMonitor.messageSystemWillPowerOn {
            let monitor = Unmanaged<PowerWakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.onWake()
        }
    }

    deinit {
        lock.lock()
        let loop = runLoop
        let port = notificationPort
        var notifier = notifier
        let connection = powerConnection
        lock.unlock()
        if let loop {
            CFRunLoopStop(loop)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        if connection != 0 {
            IOServiceClose(connection)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }
}

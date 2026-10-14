import Foundation

/// Tracks applied display overrides and restores them on process exit.
/// Handles both normal exit (deinit) and abnormal signals (SIGINT/SIGTERM).
final class OverrideTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _originalBrightness: Float?
    private var _originalWarmth: Float?
    private var _appliedWarmth: Float = 0
    private var _originalEDRBrightness: Double?
    private var _appliedEDRBrightness: Double?
    private var _originalEDRHeadroom: Double?
    private var _hasOverrides = false
    private var signalSources: [DispatchSourceSignal] = []
    private let displayWrite: any DisplayWriteServiceProtocol
    private let onRestore: (() -> Void)?

    var currentWarmth: Float {
        lock.lock()
        defer { lock.unlock() }
        return _appliedWarmth
    }

    var appliedEDRBrightness: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _appliedEDRBrightness
    }

    func hasBrightnessOverride() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _originalBrightness != nil
    }

    func hasWarmthOverride() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _originalWarmth != nil
    }

    func hasEDROverride() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _originalEDRBrightness != nil
    }

    init(displayWrite: any DisplayWriteServiceProtocol = HardwareDisplayWriteService(), onRestore: (() -> Void)? = nil) {
        self.displayWrite = displayWrite
        self.onRestore = onRestore
    }

    func registerSignalHandlers() {
        let signals: [Int32] = [SIGINT, SIGTERM]
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreAll()
                _exit(ExitCode.ok.rawValue)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func saveBrightness(_ value: Float) {
        lock.lock()
        defer { lock.unlock() }
        if _originalBrightness == nil {
            _originalBrightness = value
            _hasOverrides = true
        }
    }

    func saveWarmth(_ value: Float) {
        lock.lock()
        defer { lock.unlock() }
        _appliedWarmth = value
        if _originalWarmth == nil {
            _originalWarmth = value
            _hasOverrides = true
        }
    }

    func saveEDRBrightness(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        _appliedEDRBrightness = value
        if _originalEDRBrightness == nil {
            _originalEDRBrightness = value
            _hasOverrides = true
        }
    }

    /// Capture the system's current EDR headroom before the first override so it can be restored on exit.
    func saveOriginalEDRHeadroom(_ service: any EDROverlayServiceProtocol) {
        lock.lock()
        defer { lock.unlock() }
        guard _originalEDRHeadroom == nil else { return }
        guard let builtin = DisplayHelpers.builtinDisplayIDOrNil() else { return }
        _originalEDRHeadroom = service.systemEDRHeadroom(for: builtin)
        if _originalEDRHeadroom != nil {
            _hasOverrides = true
        }
    }

    func restoreAll() {
        lock.lock()
        let hasOverrides = _hasOverrides
        let brightness = _originalBrightness
        let warmth = _originalWarmth
        let edrHeadroom = _originalEDRHeadroom
        _originalBrightness = nil
        _originalWarmth = nil
        _originalEDRBrightness = nil
        _appliedEDRBrightness = nil
        _originalEDRHeadroom = nil
        _hasOverrides = false
        lock.unlock()

        guard hasOverrides else { return }

        // Cleanup must use the injected service too: a mock write must never
        // be followed by a real brightness or ColorSync restore on exit.
        displayWrite.restoreDisplayOverrides(
            brightness: brightness,
            resetGamma: warmth != nil || edrHeadroom != nil
        )
        onRestore?()
    }

    deinit {
        restoreAll()
    }
}

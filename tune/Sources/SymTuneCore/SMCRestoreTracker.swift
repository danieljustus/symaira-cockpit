import Foundation

/// Tracks original SMC values for fan and charge-limit overrides so they can
/// be restored when the process exits or receives SIGINT/SIGTERM.
///
/// This is the SMC counterpart to `OverrideTracker` (which handles display
/// overrides). The controller is responsible for calling `restoreAll()` on
/// teardown and from its signal handlers.
///
/// On top of the in-memory tracking, the captured originals are persisted to a
/// `0600` JSON file in the state directory at capture time. A process that is
/// killed (`SIGKILL`, panic, OOM, forced power-off) cannot run any restore
/// path, so the next process start consumes the leftover file before any new
/// override is applied — inverting the restore from "on shutdown" to
/// "on next start", the only point at which a process is guaranteed to be
/// alive.
final class SMCRestoreTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fanOriginals: [Int: (mode: UInt8, targetRPM: Double)] = [:]
    private var originalFSBitmask: UInt?
    private var originalChargeInhibit: Bool?
    private var activeChargeKeyFamily: ChargeLimitKeyFamily?
    private var hasOverrides = false

    private let smc: SMCService
    private let fanControl: FanControlService
    private let chargeLimit: ChargeLimitService
    private let restoreFileURL: URL

    init(
        smc: SMCService,
        fanControl: FanControlService,
        chargeLimit: ChargeLimitService,
        dataDir: URL? = nil
    ) {
        self.smc = smc
        self.fanControl = fanControl
        self.chargeLimit = chargeLimit
        self.restoreFileURL = (dataDir ?? ConfigPaths().dataDir)
            .appendingPathComponent("smc-restore.json")
    }

    /// Architecture string recorded next to captured values so a restore file
    /// from a different machine (or a firmware that changed key families) is
    /// never applied blindly.
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Fan tracking

    /// Save the original fan mode and target RPM before the first override.
    func saveFanOriginal(fanIndex: Int) {
        guard smc.isAvailable else { return }
        lock.lock()
        let alreadyTracked = fanOriginals[fanIndex] != nil
        if !alreadyTracked, let state = fanControl.originalState(fanIndex: fanIndex), let mode = state.mode {
            fanOriginals[fanIndex] = (mode, state.targetRPM ?? 0)
            hasOverrides = true
        }
        #if arch(x86_64)
        if originalFSBitmask == nil {
            originalFSBitmask = FanControlService.originalFSBitmask(smc: smc)
        }
        #endif
        lock.unlock()
        persistIfNeeded()
    }

    // MARK: - Charge tracking

    /// Save the original charge inhibit state before the first override.
    func saveChargeOriginal() {
        guard smc.isAvailable else { return }
        lock.lock()
        if originalChargeInhibit == nil, let family = chargeLimit.detectKeyFamily() {
            activeChargeKeyFamily = family
            switch family {
            case .chte, .ch0b:
                originalChargeInhibit = chargeLimit.readInhibitState() ?? false
            case .chlc:
                originalChargeInhibit = smc.readKeyUInt("CHLC") == 100
            }
            hasOverrides = true
        }
        lock.unlock()
        persistIfNeeded()
    }

    // MARK: - Persistence

    /// Persist the current originals to the state directory so a killed
    /// process leaves a recoverable trail. Atomic write + `0600` perms.
    private func persistIfNeeded() {
        lock.lock()
        guard hasOverrides else {
            lock.unlock()
            return
        }
        let record = SMCRestoreRecord(
            architecture: Self.currentArchitecture,
            chargeKeyFamily: activeChargeKeyFamily,
            fanOriginals: fanOriginals
                .sorted { $0.key < $1.key }
                .map { FanOriginal(fanIndex: $0.key, mode: $0.value.mode, targetRpm: $0.value.targetRPM) },
            fsBitmask: originalFSBitmask,
            chargeInhibit: originalChargeInhibit
        )
        lock.unlock()

        do {
            try StateFilePermissions.ensureDirectory(restoreFileURL.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(record)
            try data.write(to: restoreFileURL, options: .atomic)
            StateFilePermissions.applyFilePermissions(at: restoreFileURL)
        } catch {
            fputs("symtune: warning: failed to persist SMC restore state: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Apply a restore record left by a previous process that died before it
    /// could restore, then remove the file. Called once at startup, before any
    /// new override is applied.
    ///
    /// The file is never trusted blindly: a stale file from a different
    /// architecture is discarded entirely, and charge values are only applied
    /// when the recorded key family still matches the current platform.
    func consumePersistedRestore() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: restoreFileURL.path) else { return }

        guard smc.isAvailable else { return }

        guard let data = try? Data(contentsOf: restoreFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let record = try? decoder.decode(SMCRestoreRecord.self, from: data) else {
            // Corrupt leftovers cannot be trusted and must never be applied
            // later by accident — discard them.
            fputs("symtune: warning: discarding unreadable SMC restore file\n", stderr)
            try? fm.removeItem(at: restoreFileURL)
            return
        }

        guard record.version == SMCRestoreRecord.currentVersion,
              record.architecture == Self.currentArchitecture else {
            fputs(
                "symtune: warning: ignoring stale SMC restore file (architecture/version mismatch)\n",
                stderr
            )
            try? fm.removeItem(at: restoreFileURL)
            return
        }

        let fans = Dictionary(
            uniqueKeysWithValues: record.fanOriginals.map { ($0.fanIndex, ($0.mode, $0.targetRpm)) }
        )
        restoreFans(fans, record.fsBitmask)

        if let family = record.chargeKeyFamily, let charge = record.chargeInhibit {
            if family == chargeLimit.detectKeyFamily() {
                restoreCharge(charge, family)
            } else {
                fputs(
                    "symtune: warning: skipping SMC charge restore (recorded key family no longer matches)\n",
                    stderr
                )
            }
        }

        try? fm.removeItem(at: restoreFileURL)
    }

    // MARK: - Restore

    func restoreAll() {
        lock.lock()
        let fanOriginalsCopy = fanOriginals
        let fsCopy = originalFSBitmask
        let chargeInhibit = originalChargeInhibit
        let chargeFamily = activeChargeKeyFamily
        fanOriginals.removeAll()
        originalFSBitmask = nil
        originalChargeInhibit = nil
        activeChargeKeyFamily = nil
        hasOverrides = false
        lock.unlock()

        guard smc.isAvailable else { return }
        restoreFans(fanOriginalsCopy, fsCopy)
        restoreCharge(chargeInhibit, chargeFamily)
        // A clean restore clears the persisted trail; a killed process leaves
        // the file for the next start to consume.
        try? FileManager.default.removeItem(at: restoreFileURL)
    }

    private func restoreFans(
        _ originals: [Int: (mode: UInt8, targetRPM: Double)],
        _ originalFS: UInt?
    ) {
        #if arch(arm64)
        for (index, original) in originals.sorted(by: { $0.key < $1.key }) {
            _ = smc.writeKeyValue("F\(index)Md", value: Double(original.mode), dataType: "ui8 ")
            if original.mode == 1 {
                _ = smc.writeKeyValue("F\(index)Tg", value: original.targetRPM, dataType: "flt ")
            }
        }
        if !originals.isEmpty {
            _ = smc.writeKeyValue("Ftst", value: 0, dataType: "ui8 ")
        }
        #else
        if !originals.isEmpty {
            let fs = originalFS ?? 0
            _ = smc.writeKeyValue("FS!", value: Double(fs), dataType: "ui16")
            for (index, original) in originals.sorted(by: { $0.key < $1.key }) {
                if original.mode == 1 {
                    _ = smc.writeKeyValue("F\(index)Tg", value: original.targetRPM, dataType: "fpe2")
                }
            }
        }
        #endif
    }

    private func restoreCharge(_ originalInhibit: Bool?, _ family: ChargeLimitKeyFamily?) {
        guard let originalInhibit, let family else { return }
        switch family {
        case .chte:
            _ = smc.writeKeyValue("CHTE", value: originalInhibit ? 1 : 0, dataType: "ui32")
        case .ch0b:
            _ = smc.writeKeyValue("CH0B", value: originalInhibit ? 2 : 0, dataType: "ui8 ")
            _ = smc.writeKeyValue("CH0C", value: originalInhibit ? 2 : 0, dataType: "ui8 ")
        case .chlc:
            _ = smc.writeKeyValue("CHLC", value: originalInhibit ? 100 : 0, dataType: "ui16")
        }
    }

    deinit {
        restoreAll()
    }
}

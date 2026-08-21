import Foundation

/// Errors that can occur while controlling battery charge limit.
public enum ChargeLimitError: Error, Sendable, CustomStringConvertible {
    case noSMCConnection
    case keyProbeFailed
    case inhibitWriteFailed
    case allowWriteFailed
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .noSMCConnection:
            return "SMC not available"
        case .keyProbeFailed:
            return "could not find a supported charge-limit SMC key"
        case .inhibitWriteFailed:
            return "failed to inhibit charging"
        case .allowWriteFailed:
            return "failed to re-enable charging"
        case .unsupportedPlatform:
            return "this charge-limit key is not supported on the current platform"
        }
    }
}

/// Detected SMC charge-limit key family for the current platform.
public enum ChargeLimitKeyFamily: Sendable, Equatable, Codable {
    case chte
    case ch0b
    case chlc
}

/// Battery charge limit service. Writes the SMC keys that inhibit or allow
/// charging. On Apple Silicon the inhibit state is volatile (resets on sleep),
/// on Intel `CHLC` persists until cleared.
public struct ChargeLimitService: Sendable {
    private let smc: SMCService

    /// Memoises the key-family probe. Which charge-limit keys a Mac implements
    /// is fixed by its firmware, but `detectKeyFamily()` sits on the hot status
    /// path (every battery read and every override snapshot), so probing the
    /// SMC again on each call is pure overhead.
    private final class FamilyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var value: ChargeLimitKeyFamily?

        func get(_ probe: () -> ChargeLimitKeyFamily?) -> ChargeLimitKeyFamily? {
            lock.lock()
            if resolved {
                defer { lock.unlock() }
                return value
            }
            lock.unlock()

            let probed = probe()

            lock.lock()
            if !resolved {
                value = probed
                resolved = true
            }
            let result = value
            lock.unlock()
            return result
        }
    }

    private let familyCache = FamilyCache()

    public init(smc: SMCService) {
        self.smc = smc
    }

    /// Determine which charge-limit key family is available on this Mac.
    /// The result is probed once and then memoised.
    public func detectKeyFamily() -> ChargeLimitKeyFamily? {
        familyCache.get {
            #if arch(arm64)
            if smc.readKeyUInt32("CHTE") != nil { return .chte }
            if smc.readKeyUInt("CH0B") != nil { return .ch0b }
            return nil
            #else
            if smc.readKeyUInt("CHLC") != nil { return .chlc }
            return nil
            #endif
        }
    }

    /// Inhibit charging so the battery stays at or below the target percent.
    /// The value is clamped to SafetyPolicy limits and AC power is required.
    public func applyChargeLimit(percent: Int, config: TuneConfig) throws {
        guard smc.isAvailable else { throw ChargeLimitError.noSMCConnection }

        let clamped = SafetyPolicy.clamp(
            percent,
            config.chargeLimitMin,
            config.chargeLimitMax
        )

        #if arch(arm64)
        try applyAppleSiliconChargeLimit(percent: clamped)
        #else
        try applyIntelChargeLimit(percent: clamped)
        #endif
    }

    /// Re-enable charging by clearing the inhibit state.
    public func clearChargeLimit() throws {
        guard smc.isAvailable else { return }
        #if arch(arm64)
        try clearAppleSiliconChargeLimit()
        #else
        try clearIntelChargeLimit()
        #endif
    }

    /// Read the current inhibit state for the active key family, if any.
    public func readInhibitState() -> Bool? {
        guard let family = detectKeyFamily() else { return nil }
        switch family {
        case .chte:
            return smc.readKeyUInt32("CHTE").map { $0 == 1 }
        case .ch0b:
            return smc.readKeyUInt("CH0B").map { $0 == 2 }
        case .chlc:
            return nil
        }
    }

    #if arch(arm64)
    private func applyAppleSiliconChargeLimit(percent: Int) throws {
        guard let family = detectKeyFamily() else { throw ChargeLimitError.keyProbeFailed }
        switch family {
        case .chte:
            guard smc.writeKeyValue("CHTE", value: 1, dataType: "ui32") else {
                throw ChargeLimitError.inhibitWriteFailed
            }
        case .ch0b:
            guard smc.writeKeyValue("CH0B", value: 2, dataType: "ui8 ") else {
                throw ChargeLimitError.inhibitWriteFailed
            }
            // Some firmwares need CH0C as a redundant pair.
            _ = smc.writeKeyValue("CH0C", value: 2, dataType: "ui8 ")
        case .chlc:
            throw ChargeLimitError.unsupportedPlatform
        }
    }

    private func clearAppleSiliconChargeLimit() throws {
        guard smc.writeKeyValue("CHTE", value: 0, dataType: "ui32") else {
            throw ChargeLimitError.allowWriteFailed
        }
        _ = smc.writeKeyValue("CH0B", value: 0, dataType: "ui8 ")
        _ = smc.writeKeyValue("CH0C", value: 0, dataType: "ui8 ")
    }
    #endif

    #if arch(x86_64)
    private func applyIntelChargeLimit(percent: Int) throws {
        guard smc.readKeyUInt("CHLC") != nil else { throw ChargeLimitError.keyProbeFailed }
        guard smc.writeKeyValue("CHLC", value: Double(percent), dataType: "ui16") else {
            throw ChargeLimitError.inhibitWriteFailed
        }
    }

    private func clearIntelChargeLimit() throws {
        guard smc.writeKeyValue("CHLC", value: 100, dataType: "ui16") else {
            throw ChargeLimitError.allowWriteFailed
        }
    }
    #endif
}

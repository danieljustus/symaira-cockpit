import Foundation

/// On-disk snapshot of the pre-override SMC state, written the moment the
/// originals are captured so a killed process cannot strand the hardware.
///
/// The in-memory restore path (teardown, `SIGINT`/`SIGTERM`, `symtune restore`)
/// stays exactly as it is; this file is advisory and additive. A leftover file
/// is consumed (applied, then removed) at the next process start — the only
/// point at which a process is guaranteed to be alive.
public struct SMCRestoreRecord: Codable, Sendable, Equatable {
    /// Format version; bump on incompatible changes.
    public static let currentVersion = 1

    public let version: Int
    /// Architecture the values were captured on (`arm64` / `x86_64`).
    public let architecture: String
    /// Charge-limit key family the inhibit state belongs to, if any.
    public let chargeKeyFamily: ChargeLimitKeyFamily?
    public let fanOriginals: [FanOriginal]
    /// Intel `FS!` bitmask captured before the first fan override.
    public let fsBitmask: UInt?
    /// Original charge inhibit state captured before the first override.
    public let chargeInhibit: Bool?

    public init(
        version: Int = SMCRestoreRecord.currentVersion,
        architecture: String,
        chargeKeyFamily: ChargeLimitKeyFamily?,
        fanOriginals: [FanOriginal],
        fsBitmask: UInt?,
        chargeInhibit: Bool?
    ) {
        self.version = version
        self.architecture = architecture
        self.chargeKeyFamily = chargeKeyFamily
        self.fanOriginals = fanOriginals
        self.fsBitmask = fsBitmask
        self.chargeInhibit = chargeInhibit
    }
}

/// One fan's pre-override state.
public struct FanOriginal: Codable, Sendable, Equatable {
    public let fanIndex: Int
    public let mode: UInt8
    public let targetRpm: Double

    public init(fanIndex: Int, mode: UInt8, targetRpm: Double) {
        self.fanIndex = fanIndex
        self.mode = mode
        self.targetRpm = targetRpm
    }
}

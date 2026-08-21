import Foundation

/// Preset fan profiles that map to specific fan behavior.
public enum FanPreset: String, Codable, Sendable, CaseIterable {
    /// Quiet: minimum fan speed, prioritizing silence.
    case quiet
    /// Auto: let the firmware curve decide (default).
    case auto
    /// Cool: aggressive fan speed for maximum cooling.
    case cool

    public var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .auto: return "Auto"
        case .cool: return "Cool"
        }
    }

    /// The fan fraction this preset targets.
    public var fanFraction: Double {
        switch self {
        case .quiet: return 0.15
        case .auto: return 0.5
        case .cool: return 0.85
        }
    }
}

/// A temperature→speed curve point: at `temperatureC`°C, the fan should be
/// at `fraction` (0.0–1.0). Interpolated linearly between points.
public struct FanCurvePoint: Codable, Sendable {
    public let temperatureC: Double
    public let fraction: Double

    public init(temperatureC: Double, fraction: Double) {
        self.temperatureC = temperatureC
        self.fraction = fraction
    }
}

/// Temperature→speed curve for automatic fan control. Defines a set of
/// temperature thresholds with corresponding fan fractions. Between points,
/// the fan fraction is linearly interpolated.
public struct FanCurve: Codable, Sendable {
    public let name: String
    public let points: [FanCurvePoint]

    public init(name: String, points: [FanCurvePoint]) {
        self.name = name
        self.points = points.sorted { $0.temperatureC < $1.temperatureC }
    }

    /// Compute the target fan fraction at the given temperature.
    /// Returns 0.0 if no points exist.
    public func fraction(at temperatureC: Double) -> Double {
        guard !points.isEmpty else { return 0.0 }
        if let first = points.first, temperatureC <= first.temperatureC {
            return first.fraction
        }
        if let last = points.last, temperatureC >= last.temperatureC {
            return last.fraction
        }
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            if temperatureC >= a.temperatureC && temperatureC <= b.temperatureC {
                let range = b.temperatureC - a.temperatureC
                guard range > 0 else { return a.fraction }
                let t = (temperatureC - a.temperatureC) / range
                return a.fraction + t * (b.fraction - a.fraction)
            }
        }
        return points.last?.fraction ?? 0.0
    }
}

extension FanCurve {
    public static let quietCurve = FanCurve(name: "Quiet", points: [
        FanCurvePoint(temperatureC: 40, fraction: 0.10),
        FanCurvePoint(temperatureC: 60, fraction: 0.25),
        FanCurvePoint(temperatureC: 80, fraction: 0.50),
        FanCurvePoint(temperatureC: 95, fraction: 0.75),
    ])

    public static let balancedCurve = FanCurve(name: "Balanced", points: [
        FanCurvePoint(temperatureC: 35, fraction: 0.15),
        FanCurvePoint(temperatureC: 55, fraction: 0.35),
        FanCurvePoint(temperatureC: 75, fraction: 0.65),
        FanCurvePoint(temperatureC: 90, fraction: 0.90),
    ])

    public static let aggressiveCurve = FanCurve(name: "Aggressive", points: [
        FanCurvePoint(temperatureC: 30, fraction: 0.25),
        FanCurvePoint(temperatureC: 50, fraction: 0.50),
        FanCurvePoint(temperatureC: 70, fraction: 0.80),
        FanCurvePoint(temperatureC: 85, fraction: 1.00),
    ])
}

/// Errors that can occur while controlling fans.
public enum FanControlError: Error, Sendable, CustomStringConvertible {
    case noFansDetected
    case fanModeWriteRejected(Int)
    case targetRPMWriteFailed(Int)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .noFansDetected:
            return "no fans detected"
        case .fanModeWriteRejected(let index):
            return "fan \(index) rejected manual mode"
        case .targetRPMWriteFailed(let index):
            return "fan \(index) target RPM write failed"
        case .unsupportedPlatform:
            return "unsupported platform"
        }
    }
}

/// Fan control service. Handles platform-specific SMC writes for setting fan
/// speed, switching between manual and automatic modes, and restoring the
/// original state on exit.
public struct FanControlService: Sendable {
    private let smc: SMCService
    private let sensors: SensorService
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        smc: SMCService,
        sensors: SensorService,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.smc = smc
        self.sensors = sensors
        self.sleep = sleep
    }

    /// Apply a uniform fraction to all fans. The fraction is clamped to the
    /// configured safe range, floored at the soft fan floor, and each fan's
    /// target RPM is additionally floored at its firmware minimum.
    public func applyFan(fraction: Double, config: TuneConfig) throws {
        guard smc.isAvailable else {
            throw TuneError.permission("SMC not available — fan control requires a real Mac")
        }
        try SMCWritePolicy.requireThermalHeadroom(sensors: sensors)

        let clamped = SMCWritePolicy.clampFanFraction(
            fraction,
            min: config.fanFractionMin,
            max: config.fanFractionMax
        )

        let fanCount = smc.readKeyUInt("FNum").map { Int($0) } ?? 0
        guard fanCount > 0 else { throw FanControlError.noFansDetected }

        #if arch(arm64)
        try applyAppleSilicon(fraction: clamped, fanCount: fanCount)
        #else
        try applyIntel(fraction: clamped, fanCount: fanCount)
        #endif
    }

    /// Restore all fans to automatic firmware control and clear any unlock flag.
    public func restoreAuto() throws {
        guard smc.isAvailable else { return }
        let fanCount = smc.readKeyUInt("FNum").map { Int($0) } ?? 0
        guard fanCount > 0 else { throw FanControlError.noFansDetected }

        #if arch(arm64)
        for i in 0..<fanCount {
            _ = smc.writeKeyValue("F\(i)Md", value: 3, dataType: "ui8 ")
        }
        _ = smc.writeKeyValue("Ftst", value: 0, dataType: "ui8 ")
        #else
        guard let originalFS = FanControlService.originalFSBitmask(smc: smc) else { return }
        _ = smc.writeKeyValue("FS!", value: Double(originalFS), dataType: "ui16")
        #endif
    }

    // MARK: - Apple Silicon

    #if arch(arm64)
    private func applyAppleSilicon(fraction: Double, fanCount: Int) throws {
        // Unlock the diagnostic register so the SMC accepts manual mode writes.
        _ = smc.writeKeyValue("Ftst", value: 1, dataType: "ui8 ")

        for i in 0..<fanCount {
            try switchFanToManual(fanIndex: i)
            let targetRPM = try SMCWritePolicy.targetRPM(fraction: fraction, fanIndex: i, smc: smc)
            guard smc.writeKeyValue("F\(i)Tg", value: targetRPM, dataType: "flt ") else {
                throw FanControlError.targetRPMWriteFailed(i)
            }
        }
    }

    private func switchFanToManual(fanIndex: Int) throws {
        // Retry the manual-mode write with exponential backoff. The SMC may
        // briefly reject writes if thermalmonitord holds the fan controller.
        var delay: UInt64 = 50_000_000 // 50 ms in nanoseconds
        for attempt in 0..<10 {
            _ = smc.writeKeyValue("F\(fanIndex)Md", value: 1, dataType: "ui8 ")
            if smc.readFanMode(fanIndex: fanIndex) == 1 { return }
            if attempt < 9 {
                sleep(Double(delay) / 1_000_000_000)
                delay = min(delay * 2, 200_000_000)
            }
        }
        throw FanControlError.fanModeWriteRejected(fanIndex)
    }
    #endif

    // MARK: - Intel

    #if arch(x86_64)
    private func applyIntel(fraction: Double, fanCount: Int) throws {
        for i in 0..<fanCount {
            let targetRPM = try SMCWritePolicy.targetRPM(fraction: fraction, fanIndex: i, smc: smc)
            guard smc.writeKeyValue("F\(i)Tg", value: targetRPM, dataType: "fpe2") else {
                throw FanControlError.targetRPMWriteFailed(i)
            }
        }

        let bits = (1 << fanCount) - 1
        guard smc.writeKeyValue("FS!", value: Double(bits), dataType: "ui16") else {
            throw FanControlError.targetRPMWriteFailed(0)
        }
    }
    #endif

    // MARK: - Original-value capture for restore

    /// Capture the original fan state for one fan before the first override.
    public func originalState(fanIndex: Int) -> (mode: UInt8?, targetRPM: Double?)? {
        guard smc.isAvailable else { return nil }
        let mode = smc.readFanMode(fanIndex: fanIndex)
        let targetRPM = smc.readFanTargetRPM(fanIndex: fanIndex)
        return (mode, targetRPM)
    }

    #if arch(x86_64)
    /// Original value of the Intel `FS!` bitmask before any override.
    public static func originalFSBitmask(smc: SMCService) -> UInt? {
        smc.readKeyUInt("FS!")
    }
    #endif
}

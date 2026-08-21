import Foundation

/// Write-specific safety validation for SMC-controlled features (fan, charge
/// limit). Every write path routes through this policy before touching hardware.
///
/// This layer is in addition to `SafetyPolicy` constants and handles dynamic
/// checks that depend on current SMC readings (e.g. firmware fan minimum,
/// thermal emergency state, AC adapter presence).
public enum SMCWritePolicy: Sendable {
    /// Errors that can be raised during SMC write validation.
    public enum ValidationError: Error, Sendable, CustomStringConvertible {
        case noSMCConnection
        case thermalEmergency(Double)
        case fanMaxRPMUnavailable(Int)
        case chargeLimitNoACPower

        public var description: String {
            switch self {
            case .noSMCConnection:
                return "SMC connection unavailable"
            case .thermalEmergency(let celsius):
                return "thermal emergency: sensor at \(celsius)°C; refusing fan write"
            case .fanMaxRPMUnavailable(let index):
                return "fan \(index) maximum RPM unavailable"
            case .chargeLimitNoACPower:
                return "charge limit requires AC power"
            }
        }
    }

    /// Clamp a requested fan fraction to the safe range and soft floor.
    public static func clampFanFraction(_ fraction: Double, min lower: Double, max upper: Double) -> Double {
        let bounded = SafetyPolicy.clamp(fraction, lower, upper)
        return Swift.max(bounded, SafetyPolicy.fanSpeedFloor)
    }

    /// Compute the target RPM for a fan from a fraction, validating that the
    /// firmware maximum RPM is readable. The result is floored at the firmware
    /// minimum (`F{n}Mn`) so the thermal floor is never violated.
    public static func targetRPM(
        fraction: Double,
        fanIndex: Int,
        smc: SMCService
    ) throws -> Double {
        guard smc.isAvailable else { throw ValidationError.noSMCConnection }
        guard let maxRPM = smc.readFanMaxRPM(fanIndex: fanIndex), maxRPM > 0 else {
            throw ValidationError.fanMaxRPMUnavailable(fanIndex)
        }
        let minRPM = smc.readFanMinRPM(fanIndex: fanIndex) ?? 0
        let target = fraction * maxRPM
        return max(target, minRPM)
    }

    /// Refuse a manual fan write if any die sensor is above the thermal
    /// emergency threshold. Returns the highest temperature seen.
    public static func requireThermalHeadroom(sensors: SensorService) throws {
        let report = sensors.read()
        let maxTemp = report.temperatures.map(\.celsius).max() ?? 0
        guard maxTemp < SafetyPolicy.thermalOverrideCelsius else {
            throw ValidationError.thermalEmergency(maxTemp)
        }
    }

    /// Refuse to inhibit charging unless the Mac is on AC power.
    public static func requireACPower(battery: BatteryService) throws {
        guard SafetyPolicy.requireACForChargeLimit else { return }
        let report = battery.read()
        guard report.present else { return }
        if let connected = report.externalConnected, !connected {
            throw ValidationError.chargeLimitNoACPower
        }
    }
}

extension SMCService {
    /// Read the minimum RPM for a fan (`F{n}Mn`).
    public func readFanMinRPM(fanIndex: Int) -> Double? {
        readKeyValue("F\(fanIndex)Mn")
    }

    /// Read the maximum RPM for a fan (`F{n}Mx`).
    public func readFanMaxRPM(fanIndex: Int) -> Double? {
        readKeyValue("F\(fanIndex)Mx")
    }

    /// Read the current target RPM for a fan (`F{n}Tg`).
    public func readFanTargetRPM(fanIndex: Int) -> Double? {
        readKeyValue("F\(fanIndex)Tg")
    }

    /// Read the current mode for a fan (`F{n}Md` or `F{n}md`).
    /// Returns `1` for manual, `3` for system/auto, or `nil` if unavailable.
    public func readFanMode(fanIndex: Int) -> UInt8? {
        let upper = readKeyUInt("F\(fanIndex)Md").map(UInt8.init)
        if let upper, upper > 0 { return upper }
        return readKeyUInt("F\(fanIndex)md").map(UInt8.init)
    }
}

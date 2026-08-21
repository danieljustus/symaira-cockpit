import Foundation
import IOKit

/// Reads battery health from the IORegistry `AppleSmartBattery` node. Fully
/// unprivileged and works on Intel and Apple Silicon notebooks. Returns
/// `present: false` on desktops (no such node).
///
/// Raw `AppleSmartBattery` keys vary slightly across Mac models; values are
/// reported best-effort with an explanatory note.
public struct BatteryService: Sendable {
    private let source: any BatterySource
    private let isChargeLimitSupported: @Sendable () -> Bool
    /// Supplies Apple's own "Maximum Capacity" / "Condition" figures from
    /// `system_profiler SPPowerDataType`. Nil disables the Apple fields (e.g.
    /// in tests). Cached by the provider, so it never runs on a hot loop.
    private let appleHealthProvider: (any AppleBatteryHealthProviding)?

    public init(
        source: any BatterySource = HardwareBatterySource(),
        isChargeLimitSupported: @escaping @Sendable () -> Bool = { false },
        appleHealthProvider: (any AppleBatteryHealthProviding)? = nil
    ) {
        self.source = source
        self.isChargeLimitSupported = isChargeLimitSupported
        self.appleHealthProvider = appleHealthProvider
    }

    public func read() -> BatteryReport {
        let chargeLimitSupported = isChargeLimitSupported()
        switch source.readProperties() {
        case .unavailable:
            return BatteryReport(
                present: false, charging: nil, externalConnected: nil,
                currentCapacityPercent: nil, cycleCount: nil,
                designCapacityMah: nil, maxCapacityMah: nil, healthPercent: nil,
                temperatureCelsius: nil, chargeLimitSupported: false,
                notes: ["No AppleSmartBattery node — likely a desktop Mac."]
            )
        case .readFailed:
            return BatteryReport(
                present: true, charging: nil, externalConnected: nil,
                currentCapacityPercent: nil, cycleCount: nil,
                designCapacityMah: nil, maxCapacityMah: nil, healthPercent: nil,
                temperatureCelsius: nil, chargeLimitSupported: false,
                notes: ["Failed to read AppleSmartBattery properties."]
            )
        case .success(let props):
            var health: Int?
            if let design = props.designCapacity, design > 0, let rawMax = props.rawMaxCapacity {
                health = Int((Double(rawMax) / Double(design) * 100).rounded())
            }

            var percent: Int?
            if let rawMax = props.rawMaxCapacity, rawMax > 0, let rawCurrent = props.rawCurrentCapacity {
                percent = SafetyPolicy.clamp(Int((Double(rawCurrent) / Double(rawMax) * 100).rounded()), 0, 100)
            }

            var temperatureC: Double?
            if let raw = props.temperatureCentidegrees {
                temperatureC = Double(raw) / 100.0
            }

            // Apple's own figures are reported alongside, never scored. Only
            // fetched when a battery is present, and cached by the provider.
            let appleHealth = appleHealthProvider?.readAppleHealth()

            var notes = [
                "Read from raw AppleSmartBattery keys; interpretation can vary by Mac model.",
            ]
            if !chargeLimitSupported {
                notes.append("Charge-limit SMC key not detected on this Mac.")
            }

            return BatteryReport(
                present: true,
                charging: props.isCharging,
                externalConnected: props.externalConnected,
                currentCapacityPercent: percent,
                cycleCount: props.cycleCount,
                designCapacityMah: props.designCapacity,
                maxCapacityMah: props.rawMaxCapacity,
                healthPercent: health,
                temperatureCelsius: temperatureC,
                appleMaximumCapacityPercent: appleHealth?.maximumCapacityPercent,
                appleCondition: appleHealth?.condition,
                chargeLimitSupported: chargeLimitSupported,
                notes: notes
            )
        }
    }
}

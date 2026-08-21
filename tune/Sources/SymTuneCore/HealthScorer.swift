import Foundation

public struct HealthScoreResult: Sendable {
    public let score: Int
    public let message: String
    public let recommendations: [String]
}

public enum HealthScorer: Sendable {
    public static func calculateScore(
        sensors: SensorReport,
        battery: BatteryReport,
        activeOverrides: ActiveOverrides,
        isKeepAwakeActive: Bool
    ) -> HealthScoreResult {
        var score = 100
        var recommendations: [String] = []

        // 1. Thermal Pressure
        switch sensors.thermalPressure {
        case "fair":
            score -= 10
            recommendations.append("System is under fair thermal pressure. Consider cooling down.")
        case "serious":
            score -= 30
            recommendations.append("System thermal pressure is serious. Performance may be throttled.")
        case "critical":
            score -= 60
            recommendations.append("System thermal pressure is critical. Close heavy apps immediately.")
        case "unknown":
            break
        default: // nominal
            break
        }

        // 2. SMC / Sensors supported
        if !sensors.smcSupported {
            score -= 10
            recommendations.append("SMC connection failed. Detailed sensor temperatures and fan RPM are unavailable.")
        }

        // 3. Battery Health & Temperature
        if battery.present {
            if let health = battery.healthPercent {
                if health < 80 {
                    let deficit = 80 - health
                    let deduction = min(30, deficit)
                    score -= deduction
                    recommendations.append("Battery health is degraded (\(health)%). Consider servicing the battery.")
                }
            }
            if let cycles = battery.cycleCount, cycles > 1000 {
                score -= 10
                recommendations.append("Battery cycle count is high (\(cycles)).")
            }
            if let temp = battery.temperatureCelsius {
                if temp > 45.0 {
                    score -= 15
                    recommendations.append("Battery temperature is critically hot (\(String(format: "%.1f", temp))°C). Stop heavy tasks.")
                } else if temp > 35.0 {
                    score -= 5
                    recommendations.append("Battery temperature is warm (\(String(format: "%.1f", temp))°C).")
                }
            }
        }

        // 4. Power assertions (keep awake)
        if isKeepAwakeActive {
            recommendations.append("Keep-awake assertion is active, preventing system sleep.")
        }

        // 5. Overrides
        if let brightness = activeOverrides.brightness, brightness > 0.9 {
            recommendations.append("Display brightness is set very high (\(Int(brightness * 100))%), which increases power drain.")
        }
        if let dim = activeOverrides.dim, dim < 1.0 {
            recommendations.append("Software dim overlay is active (dimmed to \(Int(dim * 100))%).")
        }
        if let warmth = activeOverrides.warmth, warmth > 0.0 {
            recommendations.append("Warmth override (color shift) is active.")
        }
        if let edr = activeOverrides.edrBrightness, edr > 1.0 {
            recommendations.append("Extended EDR brightness is active (\(String(format: "%.1f", edr))x), which increases thermal load.")
        }

        // Bound score
        score = max(0, min(100, score))

        // Human readable message
        let message: String
        switch score {
        case 90...100:
            message = "System health is optimal."
        case 70...89:
            message = "System health is good, with minor warnings."
        case 50...69:
            message = "System health is degraded. Action may be required."
        default:
            message = "System health is critical. Performance or battery may be severely impacted."
        }

        if recommendations.isEmpty {
            recommendations.append("System is running optimally with no warnings.")
        }

        return HealthScoreResult(score: score, message: message, recommendations: recommendations)
    }
}

import Foundation

func mapFanControlError(_ error: FanControlError) -> TuneError {
    switch error {
    case .noFansDetected:
        return .unsupported("SMC reports no fans; fan control is unavailable")
    case .fanModeWriteRejected(let index):
        return .permission("SMC rejected manual mode for fan \(index); run with sudo")
    case .targetRPMWriteFailed(let index):
        return .permission("SMC rejected target RPM for fan \(index)")
    case .unsupportedPlatform:
        return .unsupported("Fan control is not supported on this platform")
    }
}

func mapValidationError(_ error: SMCWritePolicy.ValidationError) -> TuneError {
    switch error {
    case .noSMCConnection:
        return .permission("SMC not available for write")
    case .thermalEmergency(let celsius):
        return .permission("thermal emergency at \(celsius)°C; refusing write")
    case .fanMaxRPMUnavailable(let index):
        return .unsupported("SMC did not report maximum RPM for fan \(index)")
    case .chargeLimitNoACPower:
        return .permission("charge limit requires AC power and SMC write access")
    }
}

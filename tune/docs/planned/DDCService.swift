import Foundation
@preconcurrency import AppKit

/// DDC/CI (Display Data Channel Command Interface) service for controlling
/// external monitor brightness, contrast, and input selection.
///
/// Provides display enumeration and the public API surface. The actual
/// I2C communication requires `IOI2CConnectRef` from the IOKit I2C bridge,
/// which needs a C bridging header for proper Swift access. The core
/// capability interface lives here; the privileged helper provides the
/// elevated I2C access when needed.
public struct DDCService: Sendable {
    public init() {}

    public enum VCPCode: UInt8, Sendable {
        case brightness = 0x10
        case contrast = 0x12
        case inputSource = 0x60
    }

    public enum DDCResult: Sendable {
        case success
        case unsupported(String)
        case failed(String)
    }

    public func listExternalDisplays() -> [DisplayInfo] {
        var infos: [DisplayInfo] = []
        for screen in NSScreen.screens {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let isBuiltin = displayID != 0 ? (CGDisplayIsBuiltin(displayID) != 0) : nil
            guard isBuiltin == false else { continue }

            let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            infos.append(DisplayInfo(
                name: screen.localizedName,
                displayID: displayID,
                isBuiltin: isBuiltin,
                maxEDRHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
                potentialEDRHeadroom: potential,
                edrCapable: potential > 1.0,
                backingScaleFactor: Double(screen.backingScaleFactor)
            ))
        }
        return infos
    }

    public func setBrightness(displayID: CGDirectDisplayID, value: Int) -> DDCResult {
        let clamped = SafetyPolicy.clamp(value, 0, 100)
        return .unsupported(
            "DDC/CI write requires the privileged helper for I2C access. "
            + "Requested brightness \(clamped) for display \(displayID)."
        )
    }

    public func getBrightness(displayID: CGDirectDisplayID) -> DDCResult {
        .unsupported("DDC/CI read requires the privileged helper for I2C access.")
    }

    public func setContrast(displayID: CGDirectDisplayID, value: Int) -> DDCResult {
        let clamped = SafetyPolicy.clamp(value, 0, 100)
        return .unsupported(
            "DDC/CI write requires the privileged helper for I2C access. "
            + "Requested contrast \(clamped) for display \(displayID)."
        )
    }
}

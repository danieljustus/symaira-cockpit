import Foundation
import CoreGraphics

/// Protocol abstracting display write operations for testability.
/// Concrete implementations talk to real hardware (DisplayServices/IOKit/AppKit);
/// mock implementations enable unit testing of TuneController write paths.
public protocol DisplayWriteServiceProtocol: Sendable {
    /// Reads the built-in display brightness (0.0–1.0).
    func getBuiltinBrightness() throws -> Double

    /// Sets the built-in display brightness (0.0–1.0). Caller must clamp via SafetyPolicy.
    func setBuiltinBrightness(_ value: Float) throws

    /// Applies a warmth shift (0.0 = neutral, 1.0 = max warm) via gamma LUT.
    func applyWarmth(_ warmth: Float) throws

    /// Resets the built-in display gamma to identity (no warmth shift).
    func resetWarmth() throws

    /// Applies extended brightness via an on-screen EDR layer.
    /// - Parameter multiplier: 1.0 = SDR reference, up to SafetyPolicy.extendedBrightnessMax.
    /// - Parameter displayID: target display; nil defaults to the built-in display.
    func applyExtendedBrightness(_ multiplier: Double, displayID: UInt32?) throws

    /// Dim operations and cleanup share the same hardware boundary as gamma writes.
    func applyDim(_ value: Float)
    func resetDim()
    func getDimLevel() -> Float

    /// Restore a tracked session, including extended-brightness and ColorSync cleanup.
    func restoreDisplayOverrides(brightness: Float?, resetGamma: Bool)
}

/// Production implementation bridging to DisplayService and EDROverlayService.
public struct HardwareDisplayWriteService: DisplayWriteServiceProtocol {
    private let displayService: DisplayService
    private let edrOverlay: any EDROverlayServiceProtocol
    private let dimOverlay = DimOverlay()

    public init(
        displayService: DisplayService = DisplayService(),
        edrOverlay: any EDROverlayServiceProtocol = EDROverlayService()
    ) {
        self.displayService = displayService
        self.edrOverlay = edrOverlay
    }

    public func getBuiltinBrightness() throws -> Double {
        try displayService.getBuiltinBrightness()
    }

    public func setBuiltinBrightness(_ value: Float) throws {
        try displayService.setBuiltinBrightness(value)
    }

    public func applyWarmth(_ warmth: Float) throws {
        try displayService.applyWarmth(warmth)
    }

    public func resetWarmth() throws {
        try displayService.resetWarmth()
    }

    public func applyExtendedBrightness(_ multiplier: Double, displayID: UInt32?) throws {
        try edrOverlay.applyExtendedBrightness(multiplier, displayID: displayID)
    }

    public func applyDim(_ value: Float) { dimOverlay.applyDim(value) }
    public func resetDim() { dimOverlay.removeAllOverlays() }
    public func getDimLevel() -> Float { dimOverlay.dimLevel }

    public func restoreDisplayOverrides(brightness: Float?, resetGamma: Bool) {
        if let brightness { try? displayService.setBuiltinBrightness(brightness) }
        edrOverlay.removeAllOverlays()
        if resetGamma {
            DisplayGammaController.shared.resetAll()
            CGDisplayRestoreColorSyncSettings()
        }
    }
}

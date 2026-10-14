@preconcurrency import AppKit

/// Shared display utilities to eliminate duplication across services.
/// Extracts the "find built-in CGDirectDisplayID" and "NSScreenNumber extraction"
/// logic that was previously duplicated in DisplayService, EDROverlayService,
/// OverrideTracker, and DimOverlay.
public enum DisplayHelpers: Sendable {
    /// Extract the CGDirectDisplayID from an NSScreen's device description.
    /// Returns nil if the screen has no valid display ID.
    public static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              displayID != 0
        else {
            return nil
        }
        return CGDirectDisplayID(displayID)
    }

    /// Find the built-in display's CGDirectDisplayID.
    /// - Throws: `TuneError.unsupported` if no built-in display is found.
    public static func builtinDisplayID() throws -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            if let displayID = screenDisplayID(screen), CGDisplayIsBuiltin(displayID) != 0 {
                return displayID
            }
        }
        throw TuneError.unsupported("No built-in display detected.")
    }

    /// Find the built-in display's CGDirectDisplayID, returning nil instead of throwing.
    public static func builtinDisplayIDOrNil() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            if let displayID = screenDisplayID(screen), CGDisplayIsBuiltin(displayID) != 0 {
                return displayID
            }
        }
        return nil
    }

    /// Find the NSScreen for a given display ID.
    public static func screenForDisplayID(_ displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            if screenDisplayID(screen) == displayID {
                return screen
            }
        }
        return nil
    }
}

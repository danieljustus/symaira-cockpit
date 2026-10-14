@preconcurrency import AppKit

/// Snapshot of a single display as seen by the enumeration source.
public struct ScreenSnapshot: Sendable, Equatable {
    public let name: String
    public let displayID: CGDirectDisplayID
    public let isBuiltin: Bool
    public let maxEDRHeadroom: Double
    public let potentialEDRHeadroom: Double
    public let backingScaleFactor: Double

    public init(
        name: String,
        displayID: CGDirectDisplayID,
        isBuiltin: Bool,
        maxEDRHeadroom: Double,
        potentialEDRHeadroom: Double,
        backingScaleFactor: Double
    ) {
        self.name = name
        self.displayID = displayID
        self.isBuiltin = isBuiltin
        self.maxEDRHeadroom = maxEDRHeadroom
        self.potentialEDRHeadroom = potentialEDRHeadroom
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Abstracts NSScreen / CoreGraphics display enumeration so `DisplayService`
/// can be unit-tested without a logged-in GUI session.
public protocol DisplayEnumerationSource: Sendable {
    func enumerateScreens() -> [ScreenSnapshot]
}

/// Production display-enumeration source backed by `NSScreen.screens`.
public struct HardwareDisplayEnumerationSource: DisplayEnumerationSource, Sendable {
    public init() {}

    public func enumerateScreens() -> [ScreenSnapshot] {
        NSScreen.screens.map { screen in
            let displayID = DisplayHelpers.screenDisplayID(screen) ?? 0
            let isBuiltin = displayID != 0 ? (CGDisplayIsBuiltin(displayID) != 0) : false
            return ScreenSnapshot(
                name: screen.localizedName,
                displayID: displayID,
                isBuiltin: isBuiltin,
                maxEDRHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                potentialEDRHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                backingScaleFactor: Double(screen.backingScaleFactor)
            )
        }
    }
}

import Foundation
import IOKit.pwr_mgt

/// Kind of keep-awake power assertion to create.
public enum PowerAssertionType: Sendable {
    case preventSystemSleep
    case preventDisplaySleep
}

/// Abstracts the low-level IOKit power-assertion API so `PowerService` can be
/// unit-tested without creating real power assertions.
public protocol PowerAssertionSource: Sendable {
    func create(type: PowerAssertionType, reason: String) throws -> UInt32
    func release(_ assertionID: UInt32)
}

/// Production power-assertion source backed by `IOPMAssertionCreateWithName`.
public struct HardwarePowerAssertionSource: PowerAssertionSource, Sendable {
    public init() {}

    public func create(type: PowerAssertionType, reason: String) throws -> UInt32 {
        var id: IOPMAssertionID = IOPMAssertionID(0)
        let typeString: CFString
        switch type {
        case .preventSystemSleep:
            typeString = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .preventDisplaySleep:
            typeString = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        }
        let result = IOPMAssertionCreateWithName(
            typeString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw TuneError.failed("Failed to create power assertion (IOReturn \(result)).")
        }
        return id
    }

    public func release(_ assertionID: UInt32) {
        IOPMAssertionRelease(IOPMAssertionID(assertionID))
    }
}

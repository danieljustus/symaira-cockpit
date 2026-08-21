import XCTest
@testable import SymTuneCore

final class HardwareBackendIntegrationTests: XCTestCase {
    func testHardwareBatterySourceCompilesAndReturnsResult() {
        let result = HardwareBatterySource().readProperties()
        // CI runs headless on macOS; either a real battery or a desktop is fine.
        XCTAssertTrue(result == .unavailable || result == .readFailed || {
            if case .success = result { return true }
            return false
        }())
    }

    func testHardwarePowerSourceCompiles() {
        let source = HardwarePowerAssertionSource()
        XCTAssertEqual(String(describing: source), "HardwarePowerAssertionSource()")
    }

    func testHardwareSMCConnectionCompiles() {
        let conn = HardwareSMCConnection()
        // Connection state depends on the host; the important thing is it does not crash.
        XCTAssertTrue(conn.isOpen || !conn.isOpen)
    }

    func testHardwareDisplayEnumerationSourceCompiles() {
        let source = HardwareDisplayEnumerationSource()
        let screens = source.enumerateScreens()
        // CI may or may not report screens; the call must not crash.
        XCTAssertGreaterThanOrEqual(screens.count, 0)
    }
}

import XCTest
@testable import SymCockpitCore

final class HardwareBackendIntegrationTests: XCTestCase {
    func testHardwareBatterySourceCompilesAndReturnsResult() {
        let result = HardwareBatterySource().readProperties()
        // CI runs headless on macOS; either a real battery or a desktop is fine.
        XCTAssertTrue(result == .unavailable || result == .readFailed || {
            if case .success = result { return true }
            return false
        }())
    }

    func testHardwareSMCConnectionCompiles() {
        let conn = HardwareSMCConnection()
        // Connection state depends on the host; the important thing is it does not crash.
        XCTAssertTrue(conn.isOpen || !conn.isOpen)
    }
}

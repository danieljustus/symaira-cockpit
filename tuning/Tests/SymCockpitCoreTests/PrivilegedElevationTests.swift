import XCTest
@testable import SymCockpitCore

/// Only pure-logic pieces of `PrivilegedElevation` are tested here —
/// `runSymCockpit` itself is deliberately never exercised: on a machine
/// where `symcockpit` is actually installed (the normal case for anyone
/// developing this repo), calling it would spawn a real `osascript … with
/// administrator privileges` and pop a live system password dialog during
/// `swift test`, which must never happen from an automated test run.
final class PrivilegedElevationTests: XCTestCase {

    // MARK: - shellFormat

    func testShellFormatIsLocaleIndependent() {
        // Not directly overridable in-process, but the fixed en_US_POSIX
        // locale argument means the current locale must never leak in.
        XCTAssertEqual(PrivilegedElevation.shellFormat(0.5), "0.5000")
        XCTAssertEqual(PrivilegedElevation.shellFormat(1.0), "1.0000")
    }
}

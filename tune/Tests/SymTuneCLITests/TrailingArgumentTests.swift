import XCTest
@testable import SymTuneCLI

final class TrailingArgumentTests: XCTestCase {
    func testNumericParsersRejectTrailingArguments() throws {
        XCTAssertEqual(try parseValue(["set", "0.5"], command: "brightness"), 0.5)
        XCTAssertEqual(try parseValue(["0.5"], command: "brightness"), 0.5)
        XCTAssertEqual(try parseInt(["set", "80"], command: "battery-limit"), 80)
        for suffix in ["--dry-run", "--typo", "0.8", "set"] {
            XCTAssertThrowsError(try parseValue(["set", "0.5", suffix], command: "brightness"))
            XCTAssertThrowsError(try parseInt(["set", "80", suffix], command: "battery-limit"))
        }
    }
}

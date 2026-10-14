import XCTest
@testable import SymCockpitCLI

final class FiniteValueTests: XCTestCase {
    func testNumericWriteParserRejectsNonFiniteValues() throws {
        XCTAssertEqual(try parseValue(["set", "0.5"], command: "brightness"), 0.5)
        for value in ["nan", "NaN", "inf", "-inf", "1e309"] {
            XCTAssertThrowsError(try parseValue(["set", value], command: "brightness"), value)
        }
    }
}

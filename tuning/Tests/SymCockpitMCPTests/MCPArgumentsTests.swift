import XCTest
import SymairaMCP
@testable import SymCockpitMCP
@testable import SymCockpitCore

final class MCPArgumentsTests: XCTestCase {

    // MARK: - requireDouble

    func testRequireDoubleAcceptsNumber() throws {
        let value = try requireDouble(.number(3.14), name: "value")
        XCTAssertEqual(value, 3.14, accuracy: 0.001)
    }

    func testRequireDoubleAcceptsStringNumber() throws {
        let value = try requireDouble(.string("3.14"), name: "value")
        XCTAssertEqual(value, 3.14, accuracy: 0.001)
    }

    func testRequireDoubleRejectsInvalidString() {
        XCTAssertThrowsError(try requireDouble(.string("not-a-number"), name: "value")) { error in
            guard case TuneError.usage(let msg) = error else {
                return XCTFail("Expected .usage, got \(error)")
            }
            XCTAssertTrue(msg.contains("Missing required numeric argument 'value'"), msg)
        }
    }

    func testRequireDoubleRejectsNil() {
        XCTAssertThrowsError(try requireDouble(nil, name: "value")) { error in
            guard case TuneError.usage(let msg) = error else {
                return XCTFail("Expected .usage, got \(error)")
            }
            XCTAssertTrue(msg.contains("Missing required numeric argument 'value'"), msg)
        }
    }

    func testRequireDoubleRejectsNonFiniteValues() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try requireDouble(.number(value), name: "value"))
        }
        for value in ["nan", "inf", "-inf", "1e309"] {
            XCTAssertThrowsError(try requireDouble(.string(value), name: "value"))
        }
    }

    // MARK: - requireInt

    func testRequireIntAcceptsNumber() throws {
        let value = try requireInt(.number(42), name: "count")
        XCTAssertEqual(value, 42)
    }

    func testRequireIntAcceptsStringNumber() throws {
        let value = try requireInt(.string("42"), name: "count")
        XCTAssertEqual(value, 42)
    }

    func testRequireIntRejectsInvalidString() {
        XCTAssertThrowsError(try requireInt(.string("not-an-int"), name: "count")) { error in
            guard case TuneError.usage(let msg) = error else {
                return XCTFail("Expected .usage, got \(error)")
            }
            XCTAssertTrue(msg.contains("Missing required integer argument 'count'"), msg)
        }
    }

    func testRequireIntRejectsNil() {
        XCTAssertThrowsError(try requireInt(nil, name: "count")) { error in
            guard case TuneError.usage(let msg) = error else {
                return XCTFail("Expected .usage, got \(error)")
            }
            XCTAssertTrue(msg.contains("Missing required integer argument 'count'"), msg)
        }
    }
}

import XCTest
@testable import SymTuneCore

final class TuneErrorTests: XCTestCase {

    func testUsageDescription() {
        let error = TuneError.usage("bad flag")
        XCTAssertEqual(error.description, "bad flag")
    }

    func testConfigDescription() {
        let error = TuneError.config("missing key")
        XCTAssertEqual(error.description, "config error: missing key")
    }

    func testPermissionDescription() {
        let error = TuneError.permission("needs helper")
        XCTAssertEqual(error.description, "permission error: needs helper")
    }

    func testUnsupportedDescription() {
        let error = TuneError.unsupported("no fan")
        XCTAssertEqual(error.description, "unsupported: no fan")
    }

    func testNotImplementedDescription() {
        let error = TuneError.notImplemented("charge limit")
        XCTAssertEqual(error.description, "not implemented: charge limit")
    }

    func testFailedDescription() {
        let error = TuneError.failed("IOKit died")
        XCTAssertEqual(error.description, "IOKit died")
    }

    func testUsageExitCode() {
        XCTAssertEqual(TuneError.usage("x").exitCode, ExitCode.usage.rawValue)
    }

    func testConfigExitCode() {
        XCTAssertEqual(TuneError.config("x").exitCode, ExitCode.usage.rawValue)
    }

    func testPermissionExitCode() {
        XCTAssertEqual(TuneError.permission("x").exitCode, ExitCode.permission.rawValue)
    }

    func testUnsupportedExitCode() {
        XCTAssertEqual(TuneError.unsupported("x").exitCode, ExitCode.unsupported.rawValue)
    }

    func testNotImplementedExitCode() {
        XCTAssertEqual(TuneError.notImplemented("x").exitCode, ExitCode.unsupported.rawValue)
    }

    func testFailedExitCode() {
        XCTAssertEqual(TuneError.failed("x").exitCode, ExitCode.error.rawValue)
    }
}

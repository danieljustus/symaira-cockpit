import Foundation
import XCTest
@testable import SymTuneCLI
import SymTuneCore

/// `--data-dir` is how the GUI tells an elevated child where to write. The
/// child runs under `osascript`, which sets none of the `SUDO_*` variables the
/// state layer used to infer the calling user from, so the flag has to survive
/// argument parsing intact and out of the way of the command parsers.
final class DataDirFlagTests: XCTestCase {
    func testExtractsThePathAndRemovesBothArgumentsFromTheRest() throws {
        let (dir, rest) = try extractDataDir(["fan", "set", "0.5", "--data-dir", "/tmp/example"])

        XCTAssertEqual(dir?.path, "/tmp/example")
        XCTAssertEqual(rest, ["fan", "set", "0.5"], "the command parsers must not see the flag")
    }

    func testAcceptsTheFlagBeforeTheCommand() throws {
        let (dir, rest) = try extractDataDir(["--data-dir", "/tmp/example", "fan", "auto"])

        XCTAssertEqual(dir?.path, "/tmp/example")
        XCTAssertEqual(rest, ["fan", "auto"])
    }

    func testAbsentFlagLeavesArgumentsUntouched() throws {
        let (dir, rest) = try extractDataDir(["fan", "set", "0.5"])

        XCTAssertNil(dir)
        XCTAssertEqual(rest, ["fan", "set", "0.5"])
    }

    func testEmptyArgumentsAreHandled() throws {
        let (dir, rest) = try extractDataDir([])

        XCTAssertNil(dir)
        XCTAssertTrue(rest.isEmpty)
    }

    /// A trailing `--data-dir` with no path must be a usage error, not a crash
    /// on the index after the last element.
    func testMissingPathIsAUsageError() {
        XCTAssertThrowsError(try extractDataDir(["fan", "set", "0.5", "--data-dir"])) { error in
            guard let error = error as? TuneError else {
                return XCTFail("expected TuneError, got \(error)")
            }
            XCTAssertTrue(
                error.description.contains("--data-dir"),
                "the usage error must name the flag: \(error.description)"
            )
        }
    }

    /// A relative path stays usable — it is resolved against the process's
    /// working directory the same way any other path argument would be.
    func testRelativePathIsAccepted() throws {
        let (dir, rest) = try extractDataDir(["history", "--data-dir", "state"])

        XCTAssertNotNil(dir)
        XCTAssertTrue(dir?.path.hasSuffix("state") ?? false)
        XCTAssertEqual(rest, ["history"])
    }
}

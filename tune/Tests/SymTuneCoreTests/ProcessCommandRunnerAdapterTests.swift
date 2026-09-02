import Foundation
import XCTest
@testable import SymTuneCore

final class ProcessCommandRunnerAdapterTests: XCTestCase {
    func testSymVaultAdapterPreservesStandardInputAndOutput() throws {
        let runner = ProcessSymVaultCommandRunner(binaryName: "/bin/cat", timeout: 1)
        let result = try runner.run(arguments: [], standardInput: Data("credential\n".utf8))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, Data("credential\n".utf8))
    }

    func testSymVaultAdapterMapsTimeoutToCommandFailure() {
        let runner = ProcessSymVaultCommandRunner(binaryName: "/bin/sleep", timeout: 0.05)

        XCTAssertThrowsError(try runner.run(arguments: ["2"], standardInput: nil)) { error in
            XCTAssertEqual(error as? SymVaultCredentialError, .commandFailed(-1))
        }
    }

    func testSymBrainAdapterPreservesOutputAndEnvironmentContract() throws {
        let runner = ProcessSymBrainCommandRunner(binaryName: "/usr/bin/printf", timeout: 1)
        let result = try runner.run(arguments: ["usage output"], environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, Data("usage output".utf8))
    }

    func testSymBrainAdapterMapsTimeoutToCommandFailure() {
        let runner = ProcessSymBrainCommandRunner(binaryName: "/bin/sleep", timeout: 0.05)

        XCTAssertThrowsError(try runner.run(arguments: ["2"], environment: ["PATH": "/usr/bin:/bin"])) { error in
            XCTAssertEqual(error as? SymBrainUsageError, .commandFailed(-1))
        }
    }
}

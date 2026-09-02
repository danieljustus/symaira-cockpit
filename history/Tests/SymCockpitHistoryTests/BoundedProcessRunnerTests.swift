import Foundation
import XCTest
@testable import SymCockpitHistory

final class BoundedProcessRunnerTests: XCTestCase {
    func testResolvesExecutableThroughProvidedPATHAndCapturesBothStreams() throws {
        let result = try BoundedProcessRunner.run(
            executable: "sh",
            arguments: ["-c", "printf out; printf err >&2"],
            timeoutSeconds: 1,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "out")
        XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "err")
    }

    func testDrainsMoreThanOneMiBFromBothStreamsWithoutCorruption() throws {
        let bytesPerStream = 2 * 1024 * 1024
        let result = try BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' O; " +
                    "dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' E >&2"
            ],
            timeoutSeconds: 3,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, bytesPerStream)
        XCTAssertEqual(result.standardError.count, bytesPerStream)
        XCTAssertTrue(result.standardOutput.allSatisfy { $0 == 0x4F })
        XCTAssertTrue(result.standardError.allSatisfy { $0 == 0x45 })
    }

    func testWritesOptionalStandardInputAndClosesItAtEOF() throws {
        let result = try BoundedProcessRunner.run(
            executable: "cat",
            timeoutSeconds: 1,
            environment: ["PATH": "/bin:/usr/bin"],
            standardInput: Data("from stdin".utf8)
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output, "from stdin")
    }

    func testTimeoutTerminatesAndReapsTheChild() throws {
        let started = Date()
        let result = try BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 10"],
            timeoutSeconds: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNotEqual(result.terminationStatus, 0)
    }

    func testMissingPATHExecutableDoesNotFallBackToAUserSpecificPath() {
        XCTAssertThrowsError(try BoundedProcessRunner.run(
            executable: "definitely-not-a-real-process",
            environment: ["PATH": "/empty"]
        )) { error in
            XCTAssertEqual(
                error as? BoundedProcessRunnerError,
                .executableUnavailable("definitely-not-a-real-process")
            )
        }
    }
}

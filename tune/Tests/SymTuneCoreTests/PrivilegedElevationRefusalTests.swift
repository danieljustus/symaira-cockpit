import Foundation
import SymCockpitHistory
import XCTest
@testable import SymTuneCore

/// Elevation refuses a binary it cannot vouch for. The refusal has to stay
/// distinguishable from "not installed": one means install the CLI, the other
/// means the CLI that *is* installed sits somewhere anything could rewrite it,
/// and the user needs to be told which.
final class PrivilegedElevationRefusalTests: XCTestCase {
    func testMissingBinaryIsReportedAsNotInstalled() {
        XCTAssertThrowsError(
            try PrivilegedElevation.resolveTrustedSymCockpit(
                resolve: { throw PrivilegedExecutableError.notFound(executable: "symcockpit") }
            )
        ) { error in
            XCTAssertEqual(error as? PrivilegedElevation.ElevationError, .executableUnavailable)
        }
    }

    func testUserOwnedBinaryIsRefusedWithTheUnderlyingReason() {
        let underlying = PrivilegedExecutableError.notOwnedByRoot(
            path: "/opt/homebrew/bin/symcockpit",
            owner: "daniel"
        )

        XCTAssertThrowsError(
            try PrivilegedElevation.resolveTrustedSymCockpit(resolve: { throw underlying })
        ) { error in
            guard case .untrustedExecutable(let reason)? = error as? PrivilegedElevation.ElevationError else {
                return XCTFail("expected untrustedExecutable, got \(error)")
            }
            XCTAssertEqual(reason, underlying.description)
            XCTAssertTrue(reason.contains("/opt/homebrew/bin/symcockpit"), "names the path")
            XCTAssertTrue(reason.contains("daniel"), "names the actual owner")
            XCTAssertTrue(reason.contains("/usr/local/bin"), "names where to install instead")
        }
    }

    func testGroupWritableBinaryIsRefusedWithItsPermissions() {
        let underlying = PrivilegedExecutableError.writableByNonRoot(
            path: "/usr/local/bin/symcockpit",
            permissions: "0775"
        )

        XCTAssertThrowsError(
            try PrivilegedElevation.resolveTrustedSymCockpit(resolve: { throw underlying })
        ) { error in
            guard case .untrustedExecutable(let reason)? = error as? PrivilegedElevation.ElevationError else {
                return XCTFail("expected untrustedExecutable, got \(error)")
            }
            XCTAssertTrue(reason.contains("0775"), "names the observed permissions")
        }
    }

    func testATrustedPathIsReturnedUnchanged() throws {
        let path = try PrivilegedElevation.resolveTrustedSymCockpit(
            resolve: { "/usr/local/bin/symcockpit" }
        )
        XCTAssertEqual(path, "/usr/local/bin/symcockpit")
    }

    /// An unrelated error must not be relabelled as an elevation refusal.
    func testUnrelatedErrorsPropagateUnchanged() {
        struct Unrelated: Error {}
        XCTAssertThrowsError(
            try PrivilegedElevation.resolveTrustedSymCockpit(resolve: { throw Unrelated() })
        ) { error in
            XCTAssertTrue(error is Unrelated, "got \(error)")
        }
    }

    func testEveryElevationErrorHasAUsefulDescription() {
        XCTAssertTrue(
            PrivilegedElevation.ElevationError.executableUnavailable.description
                .contains("brew install")
        )
        XCTAssertEqual(
            PrivilegedElevation.ElevationError.untrustedExecutable("exact reason").description,
            "exact reason"
        )
        XCTAssertTrue(
            PrivilegedElevation.ElevationError.cancelledByUser.description.contains("cancelled")
        )
        XCTAssertEqual(
            PrivilegedElevation.ElevationError.failed("boom").description,
            "boom"
        )
    }
}

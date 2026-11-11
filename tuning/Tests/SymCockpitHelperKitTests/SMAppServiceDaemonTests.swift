import ServiceManagement
import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

/// Issue #411: `SMAppService` reports `.notFound` before the first
/// registration, which must not read as "the helper is not bundled".
final class SMAppServiceDaemonTests: XCTestCase {
    func testNeverRegisteredDaemonWithBundledPlistIsNotRegistered() {
        XCTAssertEqual(
            SMAppServiceDaemon.registration(for: .notFound, plistIsBundled: { true }),
            .notRegistered
        )
        // ...so a release-signed app offers the toggle instead of disabling it.
        XCTAssertEqual(
            FanHelperRouting.availability(
                optedIn: false,
                signing: .releaseSigned(teamID: "ABCDE12345"),
                registration: SMAppServiceDaemon.registration(for: .notFound, plistIsBundled: { true })
            ),
            .off
        )
    }

    func testMissingPlistStaysNotFound() {
        XCTAssertEqual(
            SMAppServiceDaemon.registration(for: .notFound, plistIsBundled: { false }),
            .notFound
        )
    }

    func testOtherStatusesMapDirectlyWithoutCheckingThePlist() {
        let cases: [(SMAppService.Status, FanHelperRegistration)] = [
            (.notRegistered, .notRegistered), (.enabled, .enabled), (.requiresApproval, .requiresApproval),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(
                SMAppServiceDaemon.registration(for: status, plistIsBundled: {
                    XCTFail("plist check only for .notFound"); return false
                }),
                expected
            )
        }
    }
}

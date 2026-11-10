import XCTest
@testable import SymCockpitCore

final class FanHelperRoutingTests: XCTestCase {
    private let signed = FanHelperSigning.releaseSigned(teamID: "ABCDE12345")

    func testUnsignedBuildsAreNeverEligibleWhateverElseIsTrue() {
        for optedIn in [true, false] {
            for registration in [FanHelperRegistration.enabled, .requiresApproval, .notRegistered, .notFound] {
                let availability = FanHelperRouting.availability(
                    optedIn: optedIn, signing: .unsigned, registration: registration
                )
                XCTAssertEqual(availability, .unavailable(.unsigned))
                XCTAssertEqual(FanHelperRouting.route(for: availability), .osascript)
            }
        }
    }

    func testOptInIsOffByDefaultEvenWhenRegistered() {
        let availability = FanHelperRouting.availability(
            optedIn: false, signing: signed, registration: .enabled
        )
        XCTAssertEqual(availability, .off)
        XCTAssertEqual(FanHelperRouting.route(for: availability), .osascript)
    }

    func testMissingDaemonPlistIsReportedAsNotBundled() {
        XCTAssertEqual(
            FanHelperRouting.availability(optedIn: true, signing: signed, registration: .notFound),
            .unavailable(.notBundled)
        )
    }

    func testPendingApprovalIsSurfacedAndKeepsTheOsascriptPath() {
        let availability = FanHelperRouting.availability(
            optedIn: true, signing: signed, registration: .requiresApproval
        )
        XCTAssertEqual(availability, .requiresApproval)
        XCTAssertEqual(FanHelperRouting.route(for: availability), .osascript)
    }

    func testOptedInButNotRegisteredKeepsTheOsascriptPath() {
        let availability = FanHelperRouting.availability(
            optedIn: true, signing: signed, registration: .notRegistered
        )
        XCTAssertEqual(availability, .notRegistered)
        XCTAssertEqual(FanHelperRouting.route(for: availability), .osascript)
    }

    func testOnlyAFullyEnabledHelperRoutesToTheHelper() {
        let availability = FanHelperRouting.availability(
            optedIn: true, signing: signed, registration: .enabled
        )
        XCTAssertEqual(availability, .enabled)
        XCTAssertEqual(FanHelperRouting.route(for: availability), .helper)
    }

    func testPreferenceDefaultsToOffInTheGrandfatheredNamespace() throws {
        let suite = "com.symaira.test.fanhelper.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FanHelperDefaults.isEnabled(defaults))
        XCTAssertTrue(FanHelperDefaults.enabledKey.hasPrefix("com.symaira.symtune."))
        defaults.set(true, forKey: FanHelperDefaults.enabledKey)
        XCTAssertTrue(FanHelperDefaults.isEnabled(defaults))
    }
}

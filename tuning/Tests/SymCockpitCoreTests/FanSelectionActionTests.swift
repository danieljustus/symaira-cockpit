import XCTest
@testable import SymCockpitCore

/// The decision behind "take the user to the right settings when fan rights
/// are missing": every availability state against every position.
final class FanSelectionActionTests: XCTestCase {
    private let governed: [FanProfile] = [.comfort, .performance]

    private let states: [FanHelperAvailability] = [
        .off, .notRegistered, .requiresApproval, .enabled,
        .unavailable(.unsigned), .unavailable(.notBundled),
    ]

    func testStandardNeverNavigatesInAnyState() {
        for state in states {
            for running in [false, true] {
                let action = FanHelperRouting.selectionAction(
                    for: .system, availability: state, governorRunning: running
                )
                XCTAssertEqual(action, .proceed(FanHelperRouting.route(for: state)), "\(state)")
            }
        }
    }

    func testOffAndNotRegisteredOpenTheHelperPreferences() {
        for state in [FanHelperAvailability.off, .notRegistered] {
            for profile in governed {
                XCTAssertEqual(
                    FanHelperRouting.selectionAction(for: profile, availability: state, governorRunning: false),
                    .openHelperPreferences, "\(state) \(profile)"
                )
            }
        }
    }

    func testPendingApprovalOpensSystemSettings() {
        for profile in governed {
            XCTAssertEqual(
                FanHelperRouting.selectionAction(
                    for: profile, availability: .requiresApproval, governorRunning: false
                ),
                .openSystemSettingsApproval
            )
        }
    }

    func testAnEnabledHelperProceedsThroughTheHelper() {
        for profile in governed {
            XCTAssertEqual(
                FanHelperRouting.selectionAction(for: profile, availability: .enabled, governorRunning: false),
                .proceed(.helper)
            )
        }
    }

    func testUnsignedAndUnbundledBuildsKeepTheOsascriptPath() {
        for state in [FanHelperAvailability.unavailable(.unsigned), .unavailable(.notBundled)] {
            for profile in governed {
                XCTAssertEqual(
                    FanHelperRouting.selectionAction(for: profile, availability: state, governorRunning: false),
                    .proceed(.osascript), "\(state)"
                )
            }
        }
    }

    func testNoHelperAtAllKeepsTheOsascriptPath() {
        for profile in FanProfile.allCases {
            XCTAssertEqual(
                FanHelperRouting.selectionAction(for: profile, availability: nil, governorRunning: false),
                .proceed(.osascript)
            )
        }
    }

    /// A governor that already runs follows the change itself: no right is
    /// missing, so nobody is sent anywhere.
    func testARunningGovernorNeedsNoRights() {
        for state in states {
            for profile in governed {
                let action = FanHelperRouting.selectionAction(
                    for: profile, availability: state, governorRunning: true
                )
                XCTAssertEqual(action, .proceed(FanHelperRouting.route(for: state)), "\(state)")
            }
        }
    }

    func testHintsExistExactlyForNavigatingActions() {
        XCTAssertNil(FanSelectionAction.proceed(.helper).hint)
        XCTAssertNil(FanSelectionAction.proceed(.osascript).hint)
        XCTAssertNotNil(FanSelectionAction.openHelperPreferences.hint)
        XCTAssertNotNil(FanSelectionAction.openSystemSettingsApproval.hint)
        XCTAssertTrue(FanSelectionAction.openHelperPreferences.hint?.contains("without an administrator password") == true)
    }
}

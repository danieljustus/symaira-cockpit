import XCTest
@testable import SymCockpitUI

/// Asset-selection checks only. These never download or replace an installed app.
final class UpdateControlAvailabilityTests: XCTestCase {
    @MainActor
    func testPublishedUniversalReleaseUsesDownloadRatherThanUnsupportedInstall() {
        // Names read from the actual v0.8.1 release, not a simulated successful update.
        XCTAssertFalse(UpdateNotificationView.supportsAutomaticInstall(assetNames: [
            "checksums.txt",
            "Symaira-Cockpit-0.8.1-macos.dmg",
            "Symaira-Cockpit-0.8.1.zip",
            "symcockpit_0.8.1_darwin_universal.tar.gz",
        ]))
        XCTAssertFalse(UpdateNotificationView.supportsAutomaticInstall(assetNames: []))
    }

    @MainActor
    func testMatchingBundleRequiresChecksumsAndRawBinaryNeverCountsAsInstalledApp() {
        #if arch(arm64)
        let platform = "darwin_arm64"
        #else
        let platform = "darwin_amd64"
        #endif
        let app = "Cockpit_\(platform).dmg"
        XCTAssertTrue(UpdateNotificationView.supportsAutomaticInstall(assetNames: ["checksums.txt", app]))
        XCTAssertFalse(UpdateNotificationView.supportsAutomaticInstall(assetNames: [app]))
        XCTAssertFalse(UpdateNotificationView.supportsAutomaticInstall(assetNames: ["checksums.txt", "Cockpit_\(platform).tar.gz"]))
        XCTAssertFalse(UpdateNotificationView.supportsAutomaticInstall(assetNames: [
            "checksums.txt", "Cockpit_\(platform).tar.gz", app,
        ]), "The shared updater selects the first match; a later bundle must not hide a raw-binary selection.")
    }
}

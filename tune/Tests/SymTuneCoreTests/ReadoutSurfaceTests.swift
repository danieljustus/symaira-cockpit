import XCTest
@testable import SymTuneCore

/// The either-or readout surface and its migration off the #224 switch
/// (issue #251).
///
/// Two things are worth holding: an upgrade must land on the surface the user
/// had already picked, and a stored `.notch` must never leave a Mac with no
/// visible surface at all.
final class ReadoutSurfaceTests: XCTestCase {

    // MARK: - Defaults and migration

    func testDefaultsToTheMenuBarOnAFreshInstall() {
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: nil, legacyNotchEnabled: false),
            .menuBar
        )
    }

    func testMigratesTheOldNotchSwitchWhenItWasOn() {
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: nil, legacyNotchEnabled: true),
            .notch
        )
    }

    func testStoredSurfaceWinsOverTheLegacySwitch() {
        // The user turned the notch off again after the migration; the stale
        // legacy boolean must not resurrect it on the next launch.
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: "menuBar", legacyNotchEnabled: true),
            .menuBar
        )
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: "notch", legacyNotchEnabled: false),
            .notch
        )
    }

    func testUnrecognisedStoredValueFallsBackToTheLegacySwitch() {
        // A value from a future build, or a hand-edited plist.
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: "hologram", legacyNotchEnabled: true),
            .notch
        )
        XCTAssertEqual(
            ReadoutSurfaceDefaults.resolve(storedSurface: "", legacyNotchEnabled: false),
            .menuBar
        )
    }

    func testRawValuesAreStableAcrossLaunches() {
        // These strings are on disk in the grandfathered defaults namespace;
        // renaming a case would silently reset everyone's preference.
        XCTAssertEqual(ReadoutSurface.menuBar.rawValue, "menuBar")
        XCTAssertEqual(ReadoutSurface.notch.rawValue, "notch")
        XCTAssertEqual(
            ReadoutSurfaceDefaults.legacyNotchEnabledKey,
            "com.symaira.symtune.notchHUD.enabled"
        )
    }

    // MARK: - Effective surface

    func testNotchFallsBackToTheMenuBarWhenTheDisplayHasNoCutout() {
        // Otherwise the status item is hidden, the HUD cannot be built, and
        // there is nothing left to click to get the preference back.
        XCTAssertEqual(
            ReadoutSurfaceDefaults.effective(.notch, notchAvailable: false),
            .menuBar
        )
    }

    func testNotchIsUsedWhenTheDisplayHasACutout() {
        XCTAssertEqual(
            ReadoutSurfaceDefaults.effective(.notch, notchAvailable: true),
            .notch
        )
    }

    func testMenuBarStaysTheMenuBarRegardlessOfTheCutout() {
        XCTAssertEqual(
            ReadoutSurfaceDefaults.effective(.menuBar, notchAvailable: true),
            .menuBar
        )
        XCTAssertEqual(
            ReadoutSurfaceDefaults.effective(.menuBar, notchAvailable: false),
            .menuBar
        )
    }
}

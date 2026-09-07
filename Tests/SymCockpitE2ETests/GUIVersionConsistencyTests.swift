import XCTest

/// The CLI, GUI, release guard and assembled bundle all use the shared
/// cockpit release source. Family package versions remain independent.
final class GUIVersionConsistencyTests: XCTestCase {
    /// `<repo>/`, derived from this file's location.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SymCockpitE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func firstMatch(_ pattern: String, in text: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            let group = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[group])
    }

    func testSharedSourceFeedsDispatcherAndGUI() throws {
        let shared = try read("Sources/SymCockpitVersion/CockpitVersion.swift")
        let dispatcher = try read("Sources/symcockpit/main.swift")
        let updateChecker = try read("Sources/symcockpit/CockpitUpdateChecker.swift")
        let app = try read("Sources/SymCockpitApp/CockpitVersion.swift")

        let sharedVersion = try firstMatch(
            #"public static let current = "([^"]+)""#,
            in: shared
        )

        XCTAssertNotNil(sharedVersion)
        XCTAssertEqual(
            shared.components(separatedBy: "public static let current =").count - 1,
            1,
            "the shared source must contain exactly one cockpit version declaration"
        )
        XCTAssertTrue(dispatcher.contains("import SymCockpitVersion"))
        XCTAssertTrue(updateChecker.contains("import SymCockpitVersion"))
        XCTAssertFalse(dispatcher.contains("static let current = \""))
        XCTAssertTrue(app.contains("import SymCockpitVersion"))
        XCTAssertTrue(app.contains("typealias CockpitAppVersion = CockpitVersion"))
        XCTAssertFalse(app.contains("static let current = \""))
    }

    func testBundleAndReleaseVerificationUseSharedSource() throws {
        let plist = try read("Sources/SymCockpitApp/Info.plist")
        let buildScript = try read("scripts/build-app.sh")
        let releaseWorkflow = try read(".github/workflows/release.yml")

        XCTAssertTrue(
            plist.contains("<string>$(COCKPIT_VERSION)</string>"),
            "the source plist must leave the bundle version for build-app substitution"
        )
        XCTAssertTrue(buildScript.contains("Sources/SymCockpitVersion/CockpitVersion.swift"))
        XCTAssertTrue(buildScript.contains("$(COCKPIT_VERSION)"))
        XCTAssertTrue(
            releaseWorkflow.contains("Sources/SymCockpitVersion/CockpitVersion.swift"),
            "release verification must read the shared source"
        )
        XCTAssertFalse(releaseWorkflow.contains("Sources/symcockpit/main.swift"))
    }

    func testApprovedAppIconIsBundledAndGuarded() throws {
        let plist = try read("Sources/SymCockpitApp/Info.plist")
        let buildScript = try read("scripts/build-app.sh")
        let smokeScript = try read("scripts/smoke-app.sh")
        let guardScript = try read("scripts/verify-app-icon.sh")
        let checksums = try read("assets/branding/AppIcon.sha256")

        XCTAssertTrue(plist.contains("<string>AppIcon</string>"))
        XCTAssertTrue(plist.contains("<string>AppIcon.icns</string>"))
        XCTAssertTrue(buildScript.contains("AppIcon.icon"))
        XCTAssertTrue(buildScript.contains("AppIcon.icns"))
        XCTAssertTrue(smokeScript.contains("verify-app-icon.sh"))
        XCTAssertTrue(guardScript.contains("diff -qr"))
        XCTAssertTrue(guardScript.contains("CFBundleIconName"))
        XCTAssertTrue(checksums.contains("16f21fb7156b6278840293db2a3cebba2137649072171b035df501ca49074b7d"))
    }
}

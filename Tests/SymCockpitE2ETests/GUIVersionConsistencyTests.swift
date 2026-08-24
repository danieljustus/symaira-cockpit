import XCTest

/// The GUI carries the product version in three places that must agree: the
/// dispatcher's `CockpitVersion.current`, the app's `CockpitAppVersion.current`
/// and the bundle's `CFBundleShortVersionString`. The release workflow only
/// guards the first against the tag, so a bump that forgets the other two would
/// ship an app that misreports itself in its own window and its Get Info panel.
///
/// The sources are read as text: the dispatcher and the app are executable
/// targets, which a test target cannot import.
final class GUIVersionConsistencyTests: XCTestCase {
    /// `<repo>/`, derived from this file's location.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SymCockpitE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
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

    func testDispatcherAppAndBundleVersionsAgree() throws {
        let dispatcher = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/symcockpit/main.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/SymCockpitApp/CockpitVersion.swift"),
            encoding: .utf8
        )
        let plist = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/SymCockpitApp/Info.plist"),
            encoding: .utf8
        )

        let dispatcherVersion = try firstMatch(#"static let current = "([^"]+)""#, in: dispatcher)
        let appVersion = try firstMatch(#"static let current = "([^"]+)""#, in: app)
        let bundleVersion = try firstMatch(
            #"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>"#,
            in: plist
        )

        XCTAssertNotNil(dispatcherVersion, "CockpitVersion.current not found in main.swift")
        XCTAssertEqual(appVersion, dispatcherVersion, "CockpitAppVersion.current is out of step with the dispatcher")
        XCTAssertEqual(bundleVersion, dispatcherVersion, "CFBundleShortVersionString is out of step with the dispatcher")
    }
}

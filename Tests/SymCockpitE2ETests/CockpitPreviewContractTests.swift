import XCTest
import SymTuneCore

/// Source safety guard and fixture validation, not a substitute for rendering.
final class CockpitPreviewContractTests: XCTestCase {
    func testDesignPreviewRemainsIsolatedAndFixturesDecode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = root.appendingPathComponent("tune/Sources/SymTuneUI/CockpitDesignPreview.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(source.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(source.hasSuffix("#endif\n"))
        XCTAssertFalse(source.contains("try!"), "preview fixtures must not use forced decoding")
        XCTAssertFalse(source.contains("try?"), "invalid fixtures must not disappear silently")
        XCTAssertTrue(source.contains("preconditionFailure(\"Invalid Cockpit design fixture"))
        XCTAssertTrue(source.contains("Beispieldaten · Keine Hardwarezugriffe"))
        XCTAssertEqual(source.components(separatedBy: "#Preview(").count - 1, 3)
        for unsafe in ["TuneController", "StatusBarController", "MainStatusView",
                       "DisplayControlsCard", "PreferencesManager", "NSApp",
                       ".task", ".onAppear", "Process(", "URLSession"] {
            XCTAssertFalse(source.contains(unsafe), "preview acquired a live dependency: \(unsafe)")
        }
        for component in ["TuneSliderRow(", "CenterAnchoredSliderRow(",
                          "FanProfileSliderRow(", "KeepAwakeCard(", "SystemStatusCard(", "DisplaysCard("] {
            XCTAssertTrue(source.contains(component), "production component missing: \(component)")
        }

        let pattern = ##"#"""\s*(.*?)\s*"""#"##
        let regex = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        let range = NSRange(source.startIndex..., in: source)
        let fixtures = regex.matches(in: source, range: range).map { match in
            String(source[Range(match.range(at: 1), in: source)!])
        }
        XCTAssertEqual(fixtures.count, 2)
        let sensors = try JSONDecoder().decode(SensorReport.self, from: Data(XCTUnwrap(fixtures.first).utf8))
        XCTAssertEqual(sensors.thermalPressure, "nominal")
        XCTAssertEqual(sensors.temperatures.first?.key, "DEMO")
        let displays = try JSONDecoder().decode([DisplayInfo].self, from: Data(XCTUnwrap(fixtures.last).utf8))
        XCTAssertEqual(displays.count, 2)
        XCTAssertEqual(displays.map(\.displayID), [1, 2])
        XCTAssertTrue(displays.allSatisfy { $0.name.hasPrefix("Demo ") })
    }
}

import XCTest
@testable import SymTuneCore

final class RefreshIntervalValidationTests: XCTestCase {
    func testEditableIntervalsRejectInvalidTextWithoutSubstitution() {
        for text in ["", " ", "abc", "0.5", "0", "-1", "nan", "inf", "-inf", "1e309", "1e30", "86401", "3,5"] {
            XCTAssertNil(TuneConfig.validatedRefreshInterval(text), text)
        }
        for (text, expected) in [("1", 1.0), ("3", 3.0), ("5", 5.0), ("10", 10.0),
                                 ("3.5", 3.5), ("1.25", 1.25), (" 3.5 ", 3.5), ("86400", 86400.0)] {
            XCTAssertEqual(TuneConfig.validatedRefreshInterval(text), expected, text)
        }
    }

    func testConfigurationKeepsPollingIntervalsFiniteAndBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ConfigPaths(env: [:], home: root)
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(String, TimeInterval)] = [
            ("nan", 3), ("inf", 3), ("-inf", 3),
            ("1e30", 86400), ("0.5", 1), ("3.5", 3.5), ("86400", 86400),
        ]
        for (text, expected) in cases {
            let input = try XCTUnwrap(TimeInterval(text), text)
            XCTAssertEqual(TuneConfig(metricsRefreshInterval: input).metricsRefreshInterval, expected, text)
            try "[metrics]\nrefresh_interval_seconds = \(text)\n".write(
                to: paths.configFile, atomically: true, encoding: .utf8
            )
            XCTAssertEqual(TuneConfig.load(paths: paths, env: [:]).metricsRefreshInterval, expected, text)
            XCTAssertEqual(
                TuneConfig.load(paths: paths, env: ["SYMTUNE_METRICS_INTERVAL": text]).metricsRefreshInterval,
                expected, text
            )
        }
    }
}

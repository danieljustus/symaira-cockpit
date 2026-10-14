import Foundation
import SymCockpitCore
import XCTest
@testable import SymCockpitUI

final class PreferencesPersistenceTests: XCTestCase {
    @MainActor
    func testSavePreservesUnrelatedSectionsAndIgnoresCommentHeaders() throws {
        let preserved = "[safety] # keep this section\nbrightness_min = 0.23\n"
        let fixtures = [
            "# Example [metrics] configuration\n" + preserved,
            "[metrics] # sampling\nrefresh_interval_seconds = 3\n\n" + preserved,
            "[metrics] # example [cpu]\nrefresh_interval_seconds = 3\n\n" + preserved,
            "[metrics]\nrefresh_interval_seconds = 3\n\n[[external.items]]\nname = 'keep'\n" + preserved,
            "# Example [popover] configuration\n[popover] # cards\ncards = []\n\n" + preserved,
        ]
        for original in fixtures {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let paths = ConfigPaths(env: [:], home: home)
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
            try original.write(to: paths.configFile, atomically: true, encoding: .utf8)
            let manager = PreferencesManager(configPaths: paths)
            manager.metricsRefreshInterval = 7.5
            manager.visibleCards = [.keepAwake]

            try manager.writeToConfig()
            let saved = try String(contentsOf: paths.configFile, encoding: .utf8)
            XCTAssertTrue(saved.contains(preserved), original)
            XCTAssertEqual(saved.components(separatedBy: .newlines).filter { $0.hasPrefix("[metrics]") }.count, 1)
            XCTAssertEqual(saved.components(separatedBy: .newlines).filter { $0.hasPrefix("[popover]") }.count, 1)
            if original.hasPrefix("#") {
                XCTAssertEqual(saved.components(separatedBy: .newlines).first,
                               original.components(separatedBy: .newlines).first)
            }
            if original.contains("[[external.items]]") {
                XCTAssertTrue(saved.contains("[[external.items]]\nname = 'keep'\n"))
            }
            let reloaded = paths.loadConfig(env: [:])
            XCTAssertEqual(reloaded.metricsRefreshInterval, 7.5)
            XCTAssertEqual(reloaded.visibleCards, [.keepAwake])
            XCTAssertEqual(TOMLParser().parse(saved)["safety", "brightness_min"]?.doubleValue, 0.23)
            try manager.writeToConfig()
            XCTAssertEqual(try String(contentsOf: paths.configFile, encoding: .utf8), saved,
                           "Saving twice must not duplicate managed sections")
        }
    }

    @MainActor
    func testSaveRejectsUnreadableContentWithoutOverwritingIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ConfigPaths(env: [:], home: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        let original = Data([0xFF, 0xFE, 0x80, 0x00])
        try original.write(to: paths.configFile)
        let manager = PreferencesManager(configPaths: paths)

        XCTAssertThrowsError(try manager.writeToConfig())
        XCTAssertEqual(try Data(contentsOf: paths.configFile), original)
    }

    @MainActor
    func testSaveCreatesMissingConfigAndReloadsAllMetricPreferences() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ConfigPaths(env: [:], home: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = PreferencesManager(configPaths: paths)
        manager.enabledMetrics = [.memory, .cpu]
        manager.visibleMetrics = [.memory]
        manager.metricOrder = [.memory, .cpu, .network, .disk]
        manager.metricsRefreshInterval = 2.5
        manager.showCalendarWeek = true
        manager.visibleCards = [.displayControls, .keepAwake]

        try manager.writeToConfig()
        let reloaded = paths.loadConfig(env: [:])
        XCTAssertEqual(reloaded.enabledMetrics, manager.enabledMetrics)
        XCTAssertEqual(reloaded.visibleMetrics, manager.visibleMetrics)
        XCTAssertEqual(reloaded.metricOrder, manager.metricOrder)
        XCTAssertEqual(reloaded.metricsRefreshInterval, manager.metricsRefreshInterval)
        XCTAssertEqual(reloaded.showCalendarWeek, manager.showCalendarWeek)
        XCTAssertEqual(reloaded.visibleCards, manager.visibleCards)
    }
}

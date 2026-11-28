import XCTest
@testable import SymCockpitCore

final class AIUsagePriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let thresholds = AIUsageThresholds(warning: 0.8, critical: 0.95)

    private func item(_ id: String, _ used: Double, resetIn: TimeInterval? = nil, pinned: Bool = false) -> AIUsagePriorityItem {
        AIUsagePriorityItem(providerID: "p", metricID: id, usedFraction: used,
                            resetsAt: resetIn.map { now.addingTimeInterval($0) }, pinned: pinned)
    }

    func testSeverityFollowsTheThresholds() {
        XCTAssertEqual(thresholds.severity(usedFraction: 0.79), .normal)
        XCTAssertEqual(thresholds.severity(usedFraction: 0.8), .warning)
        XCTAssertEqual(thresholds.severity(usedFraction: 0.95), .critical)
        XCTAssertEqual(thresholds.severity(usedFraction: 1), .usedUp)
        XCTAssertEqual(AIUsageThresholds(warning: 0.9, critical: 0.5).critical, 0.9, "critical never below warning")
    }

    func testTheDocumentedOrder() {
        let items = [
            item("calm", 0.2),
            item("warn-low", 0.81),
            item("lose-it", 0.1, resetIn: 3600),
            item("critical", 0.97),
            item("pinned-calm", 0.1, pinned: true),
            item("warn-high", 0.9, resetIn: 7200),
            item("used-up", 1.0),
            item("warn-high-later", 0.9, resetIn: 9000),
            item("far-reset", 0.1, resetIn: 3 * 86400),
        ]
        let order = AIUsagePriority.ordered(items, thresholds: thresholds, now: now).map(\.metricID)
        XCTAssertEqual(order, ["pinned-calm", "used-up", "critical", "warn-high", "warn-high-later", "warn-low", "lose-it"])
    }

    func testTheStripShowsTheCountAndTheRestAsOverflow() {
        let items = [item("a", 0.99), item("b", 0.9), item("c", 0.85), item("d", 0.1)]
        let strip = AIUsagePriority.strip(items, thresholds: thresholds, now: now, count: 2)
        XCTAssertEqual(strip.shown.map(\.metricID), ["a", "b"])
        XCTAssertEqual(strip.overflow, 1)
    }

    func testAlertsFireOnUpwardCrossingsOnly() {
        var alerts = AIUsageQuotaAlerts()
        XCTAssertEqual(alerts.evaluate([item("a", 0.9)], thresholds: thresholds), [], "a first sighting is silent")
        XCTAssertEqual(alerts.evaluate([item("a", 0.92)], thresholds: thresholds), [], "same level: no repeat")
        XCTAssertEqual(alerts.evaluate([item("a", 0.96)], thresholds: thresholds).map(\.severity), [.critical])
        XCTAssertEqual(alerts.evaluate([], thresholds: thresholds), [], "a failed round changes nothing")
        XCTAssertEqual(alerts.evaluate([item("a", 1)], thresholds: thresholds).map(\.severity), [.usedUp])
        XCTAssertEqual(alerts.evaluate([item("a", 0.1)], thresholds: thresholds), [], "a reset is not an alert")
        XCTAssertEqual(alerts.evaluate([item("a", 0.85)], thresholds: thresholds).map(\.severity), [.warning], "re-armed")
    }
}

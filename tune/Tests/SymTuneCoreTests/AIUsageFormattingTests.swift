import XCTest
@testable import SymTuneCore

final class AIUsageFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_289_600) // 2026-07-17T12:00:00Z

    // MARK: Countdown

    func testCountdownDaysAndHours() {
        let reset = now.addingTimeInterval(2 * 86_400 + 4 * 3_600)
        XCTAssertEqual(AIUsageFormatting.countdownText(until: reset, now: now), "2d 4h")
    }

    func testCountdownHoursAndMinutes() {
        let reset = now.addingTimeInterval(3 * 3_600 + 5 * 60)
        XCTAssertEqual(AIUsageFormatting.countdownText(until: reset, now: now), "3h 05m")
    }

    func testCountdownMinutes() {
        let reset = now.addingTimeInterval(12 * 60)
        XCTAssertEqual(AIUsageFormatting.countdownText(until: reset, now: now), "12m")
    }

    func testCountdownSeconds() {
        let reset = now.addingTimeInterval(45)
        XCTAssertEqual(AIUsageFormatting.countdownText(until: reset, now: now), "45s")
    }

    func testCountdownClampsAtZero() {
        let reset = now.addingTimeInterval(-60)
        XCTAssertEqual(AIUsageFormatting.countdownText(until: reset, now: now), "0s")
    }

    func testCountdownWithoutReset() {
        XCTAssertEqual(AIUsageFormatting.countdownText(until: nil, now: now), "—")
    }

    // MARK: Remaining text

    func testRemainingPercentMeter() {
        let meter = AIUsageMeter(label: "5h window", used: 58, limit: 100, unit: .percent)
        XCTAssertEqual(AIUsageFormatting.remainingText(for: meter), "42% left")
    }

    func testRemainingRequestsMeter() {
        let meter = AIUsageMeter(label: "Weekly quota", used: 214, limit: 2048, unit: .requests)
        XCTAssertEqual(AIUsageFormatting.remainingText(for: meter), "1834 of 2048 requests left")
    }

    func testRemainingCurrencyMeter() {
        let meter = AIUsageMeter(label: "On-demand", used: 734, limit: 10_000, unit: .currency("USD"))
        XCTAssertEqual(AIUsageFormatting.remainingText(for: meter), "$92.66 of $100.00 left")
    }

    func testRemainingWithoutLimitFallsBackToUsed() {
        let meter = AIUsageMeter(label: "Cash balance", used: 42, limit: nil, unit: .currency("USD"))
        XCTAssertEqual(AIUsageFormatting.remainingText(for: meter), "$0.42 used")
    }

    // MARK: Progress fraction

    func testProgressFractionPercent() {
        let meter = AIUsageMeter(label: "Plan", used: 95, limit: 100, unit: .percent)
        XCTAssertEqual(AIUsageFormatting.progressFraction(for: meter) ?? -1, 0.95, accuracy: 0.0001)
    }

    func testProgressFractionRequests() {
        let meter = AIUsageMeter(label: "Weekly", used: 512, limit: 2048, unit: .requests)
        XCTAssertEqual(AIUsageFormatting.progressFraction(for: meter) ?? -1, 0.25, accuracy: 0.0001)
    }

    func testProgressFractionClampsAndMissing() {
        let over = AIUsageMeter(label: "Plan", used: 150, limit: 100, unit: .percent)
        XCTAssertEqual(AIUsageFormatting.progressFraction(for: over) ?? -1, 1.0)
        let noUsed = AIUsageMeter(label: "Plan", used: nil, limit: 100, unit: .percent)
        XCTAssertNil(AIUsageFormatting.progressFraction(for: noUsed))
    }

    // MARK: Status item text

    func testStatusItemTextUsesPrimaryMeterPercent() {
        let snapshot = AIUsageSnapshot(
            providerID: "cursor",
            meters: [AIUsageMeter(label: "Plan usage", used: 42, limit: 100, unit: .percent)],
            fetchedAt: now,
            source: "web"
        )
        XCTAssertEqual(AIUsageFormatting.statusItemText(for: snapshot), "42%")
    }

    func testStatusItemTextWithoutSnapshot() {
        XCTAssertEqual(AIUsageFormatting.statusItemText(for: nil), "—")
    }
}

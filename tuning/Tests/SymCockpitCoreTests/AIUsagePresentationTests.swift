import XCTest
@testable import SymCockpitCore

final class AIUsagePresentationTests: XCTestCase {
    private func metric(_ meter: AIUsageMeter) -> AIUsageMetric {
        AIUsageMetric.metrics(provider: "p", meters: [meter])[0]
    }

    func testStableProviderLabelIdentityAndRepeatedLabels() {
        let a = AIUsageMeter(label: "Weekly", used: 20, unit: .percent)
        let b = AIUsageMeter(label: "Session", used: 10, unit: .percent)
        let repeatLabel = AIUsageMeter(label: "Weekly", used: 30, unit: .percent)
        let first = AIUsageMetric.metrics(provider: "p", meters: [a, a, b, repeatLabel])
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first.map(\.id)).count, 3)
        XCTAssertEqual(first[0].id, AIUsageMetric.metrics(provider: "p", meters: [b, a])[1].id)
        XCTAssertNotEqual(first[0].id, AIUsageMetric.metrics(provider: "q", meters: [a])[0].id)
        XCTAssertNotEqual(first[0].id, first[2].id)
    }

    func testTwoPinLimitAndUnstar() {
        var layout = AIUsageLayout()
        XCTAssertTrue(layout.togglePin("a", provider: "p"))
        XCTAssertTrue(layout.togglePin("b", provider: "p"))
        XCTAssertFalse(layout.togglePin("c", provider: "p"))
        XCTAssertTrue(layout.togglePin("c", provider: "q"))
        XCTAssertTrue(layout.togglePin("a", provider: "p"))
        XCTAssertTrue(layout.togglePin("c", provider: "p"))
        XCTAssertEqual(layout.pins["p"], ["b", "c"])
    }

    func testMissingNeverBecomesZeroOrFullRemaining() {
        let missing = metric(.init(label: "Requests", limit: 100, unit: .requests))
        XCTAssertNil(missing.value(remaining: true))
        XCTAssertNil(missing.value(remaining: false))
        XCTAssertNil(missing.fraction(remaining: true))
        XCTAssertNil(missing.reset(absolute: false, now: .now))
    }

    func testUsedRemainingAndOverLimitClamping() {
        let quota = metric(.init(label: "Requests", used: 25, limit: 100, unit: .requests))
        XCTAssertEqual(quota.value(remaining: true), "75 requests")
        XCTAssertEqual(quota.value(remaining: false), "25 requests")
        XCTAssertEqual(quota.fraction(remaining: true), 0.75)
        XCTAssertEqual(quota.fraction(remaining: false), 0.25)
        let exhausted = metric(.init(label: "Requests", used: 120, limit: 100, unit: .requests))
        XCTAssertEqual(exhausted.value(remaining: true), "0 requests")
        XCTAssertEqual(exhausted.fraction(remaining: true), 0)
    }

    func testUnboundedTextButNoBar() {
        let spend = metric(.init(label: "Spend", used: 12.5, unit: .currency("USD")))
        XCTAssertEqual(spend.value(remaining: true), "12.50 USD")
        XCTAssertNil(spend.fraction(remaining: false))
    }

    func testCountdownTicksWithoutNewSnapshot() {
        let now = Date(timeIntervalSince1970: 1000)
        let quota = metric(.init(label: "Weekly", unit: .percent, resetsAt: now.addingTimeInterval(90)))
        XCTAssertEqual(quota.reset(absolute: false, now: now), "Resets in 1m")
        XCTAssertEqual(quota.reset(absolute: false, now: now.addingTimeInterval(60)), "Resets in 30s")
        XCTAssertEqual(quota.reset(absolute: true, now: now), quota.reset(absolute: true, now: now.addingTimeInterval(60)))
    }

    func testOrderMergesNewAndRemovesStaleDuplicates() {
        XCTAssertEqual(AIUsageLayout.ordered(["b", "b", "gone"], available: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(AIUsageLayout.moving("c", before: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(AIUsageLayout.moving("missing", before: "a", in: ["a"]), ["a"])
    }

    func testLayoutRoundTripPreservesAllCustomization() throws {
        var layout = AIUsageLayout()
        layout.remaining = false
        layout.absoluteReset = true
        layout.bars = true
        layout.pins = ["p": ["a", "b"]]
        layout.metricOrder = ["p": ["b", "a"]]
        layout.hidden = ["a"]
        layout.onDemand = ["b"]
        layout.expanded = ["p"]
        XCTAssertEqual(try JSONDecoder().decode(AIUsageLayout.self, from: JSONEncoder().encode(layout)), layout)
    }
}

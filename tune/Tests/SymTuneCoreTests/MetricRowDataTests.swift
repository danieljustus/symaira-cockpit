import XCTest
@testable import SymTuneCore

final class MetricRowDataTests: XCTestCase {

    // MARK: - MetricRowData

    private func row(
        current: String = "50%",
        minimum: String = "10%",
        maximum: String = "90%",
        samples: [MetricSample] = []
    ) -> MetricRowData {
        MetricRowData(
            id: .cpu,
            title: "CPU",
            current: current,
            minimum: minimum,
            maximum: maximum,
            samples: samples
        )
    }

    func testRowCarriesThePreparedFields() {
        let samples = [MetricSample.sample(42)]
        let row = MetricRowData(
            id: .memory,
            title: "Memory",
            current: "8.0 GB",
            minimum: "6.0 GB",
            maximum: "9.5 GB",
            samples: samples
        )
        XCTAssertEqual(row.id, .memory)
        XCTAssertEqual(row.title, "Memory")
        XCTAssertEqual(row.current, "8.0 GB")
        XCTAssertEqual(row.minimum, "6.0 GB")
        XCTAssertEqual(row.maximum, "9.5 GB")
        XCTAssertEqual(row.samples, samples)
    }

    func testRowsAreEquatableSoTheCardCanSkipRedraws() {
        XCTAssertEqual(row(), row())
        XCTAssertNotEqual(row(current: "50%"), row(current: "51%"))
        XCTAssertNotEqual(row(minimum: "10%"), row(minimum: "11%"))
        XCTAssertNotEqual(row(maximum: "90%"), row(maximum: "91%"))
        XCTAssertNotEqual(row(samples: [MetricSample.sample(1)]), row())
    }

    // MARK: - MetricOrdering

    func testOrderingKeepsOnlySelectedMetricsInUserOrder() {
        let order: [MetricIdentifier] = [.memory, .cpu, .disk, .network]
        let selected: Set<MetricIdentifier> = [.cpu, .network]
        XCTAssertEqual(
            MetricOrdering.ordered(selected, order: order),
            [.cpu, .network]
        )
    }

    func testOrderingFallsBackWhenNothingIsSelected() {
        let order: [MetricIdentifier] = [.memory, .cpu]
        XCTAssertEqual(
            MetricOrdering.ordered([], order: order, fallback: [.cpu, .memory]),
            [.cpu, .memory]
        )
    }

    func testOrderingFallsBackWhenNoOrderIsConfigured() {
        let selected: Set<MetricIdentifier> = [.cpu, .memory]
        XCTAssertEqual(
            MetricOrdering.ordered(selected, order: [], fallback: [.cpu, .memory]),
            [.cpu, .memory]
        )
    }

    func testOrderingDefaultsTheFallbackToEmpty() {
        XCTAssertEqual(MetricOrdering.ordered([], order: [.cpu]), [])
        XCTAssertEqual(MetricOrdering.ordered([.cpu], order: []), [])
    }

    func testOrderingReturnsEmptyWhenSelectedAndOrderDisagree() {
        // The selected set is non-empty and an order exists, so the filter
        // rule applies even when its result is empty.
        let order: [MetricIdentifier] = [.memory, .disk]
        let selected: Set<MetricIdentifier> = [.cpu]
        XCTAssertEqual(MetricOrdering.ordered(selected, order: order), [])
    }
}

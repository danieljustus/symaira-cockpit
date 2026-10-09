import XCTest
@testable import SymTuneCore

final class DecodedMetricCapacityTests: XCTestCase {
    func testDecodedStorageKeepsOnlyTheNewestSamplesWithinEffectiveCapacity() throws {
        struct Payload: Encodable {
            let capacity: Int
            let storage: [MetricSample]
        }
        let samples: [MetricSample] = [
            .sample(timestamp: Date(timeIntervalSinceReferenceDate: 1), 10),
            .gap(timestamp: Date(timeIntervalSinceReferenceDate: 2), reason: "sleep"),
            .sample(timestamp: Date(timeIntervalSinceReferenceDate: 3), 30),
            .gap(timestamp: Date(timeIntervalSinceReferenceDate: 4), reason: "unavailable"),
        ]
        for capacity in [-2, 0, 1, 3, 4, 10] {
            let data = try JSONEncoder().encode(Payload(capacity: capacity, storage: samples))
            let restored = try JSONDecoder().decode(MetricsRingBuffer.self, from: data)
            let effectiveCapacity = max(1, capacity)
            XCTAssertEqual(restored.capacity, effectiveCapacity)
            XCTAssertEqual(restored.samples, Array(samples.suffix(effectiveCapacity)))
            XCTAssertLessThanOrEqual(restored.count, restored.capacity)
            let roundTrip = try JSONDecoder().decode(
                MetricsRingBuffer.self, from: JSONEncoder().encode(restored)
            )
            XCTAssertEqual(roundTrip.samples, restored.samples)
            restored.recordValue(50, timestamp: Date(timeIntervalSinceReferenceDate: 5))
            XCTAssertEqual(restored.latestValue, 50)
            XCTAssertLessThanOrEqual(restored.count, restored.capacity)
        }
    }
}

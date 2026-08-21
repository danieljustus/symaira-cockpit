import XCTest
@testable import SymTuneCore

final class MetricsRingBufferTests: XCTestCase {

    // MARK: - Capacity enforcement

    func testCapacityEnforcement() {
        let buf = MetricsRingBuffer(capacity: 5)
        // Fill beyond capacity
        for i in 1...10 {
            buf.recordValue(Double(i))
        }
        let values = buf.valueSamples.map { $0.value! }
        // Should only keep last 5
        XCTAssertEqual(values, [6, 7, 8, 9, 10])
        XCTAssertEqual(buf.count, 5)
    }

    func testCapacityNeverExceeded() {
        let buf = MetricsRingBuffer(capacity: 3)
        for i in 1...100 {
            buf.recordValue(Double(i))
        }
        XCTAssertEqual(buf.count, 3)
        let values = buf.valueSamples.map { $0.value! }
        XCTAssertEqual(values, [98, 99, 100])
    }

    func testCapacityIncludesGaps() {
        let buf = MetricsRingBuffer(capacity: 4)
        buf.recordValue(1)
        buf.recordGap(reason: "sleep")
        buf.recordValue(2)
        buf.recordValue(3)
        buf.recordValue(4) // should evict the first value
        XCTAssertEqual(buf.count, 4)
        // First value (1) should be gone
        let values = buf.valueSamples.map { $0.value! }
        XCTAssertEqual(values, [2, 3, 4])
    }

    // MARK: - Eviction order (FIFO)

    func testEvictionOrder() {
        let buf = MetricsRingBuffer(capacity: 3)
        buf.recordValue(1)
        buf.recordValue(2)
        buf.recordValue(3)
        buf.recordValue(4) // evicts 1
        buf.recordValue(5) // evicts 2
        let values = buf.valueSamples.map { $0.value! }
        XCTAssertEqual(values, [3, 4, 5])
    }

    // MARK: - Gap handling

    func testGapMarkersPersist() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(1)
        buf.recordGap(reason: "sleep")
        buf.recordValue(2)
        buf.recordGap(reason: nil)
        buf.recordValue(3)

        let all = buf.samples
        XCTAssertEqual(all.count, 5)

        // Check gap positions
        XCTAssertEqual(all[0].value, 1)
        XCTAssertNil(all[1].value)
        XCTAssertEqual(all[1].gapReason, "sleep")
        XCTAssertEqual(all[2].value, 2)
        XCTAssertNil(all[3].value)
        XCTAssertNil(all[3].gapReason)
        XCTAssertEqual(all[4].value, 3)
    }

    func testGapsSplitSegments() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(1)
        buf.recordValue(2)
        buf.recordGap(reason: "wake")
        buf.recordValue(3)
        buf.recordValue(4)

        // valueSamples should skip gaps
        let values = buf.valueSamples.map { $0.value! }
        XCTAssertEqual(values, [1, 2, 3, 4])

        // Full samples include gaps
        let all = buf.samples
        XCTAssertEqual(all.count, 5)
        XCTAssertNil(all[2].value) // gap at index 2
    }

    func testConsecutiveGaps() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordGap(reason: "a")
        buf.recordGap(reason: "b")
        buf.recordGap(reason: "c")
        buf.recordValue(42)

        let all = buf.samples
        XCTAssertEqual(all.count, 4)
        // Three gaps then one value
        for i in 0..<3 {
            XCTAssertNil(all[i].value)
        }
        XCTAssertEqual(all[3].value, 42)
        XCTAssertEqual(buf.valueSamples.count, 1)
    }

    // MARK: - Empty buffer / no values

    func testEmptyBufferReturnsEmpty() {
        let buf = MetricsRingBuffer(capacity: 10)
        XCTAssertTrue(buf.isEmpty)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(buf.samples, [])
        XCTAssertEqual(buf.valueSamples, [])
        XCTAssertNil(buf.latestValue)
        XCTAssertNil(buf.currentMinMax)
        XCTAssertNil(buf.span)
    }

    func testOnlyGapsYieldsNoValues() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordGap()
        buf.recordGap()
        buf.recordGap()
        XCTAssertEqual(buf.count, 3)
        XCTAssertFalse(buf.isEmpty)
        XCTAssertEqual(buf.valueSamples.count, 0)
        XCTAssertNil(buf.latestValue)
        XCTAssertNil(buf.currentMinMax)
    }

    // MARK: - Min/max

    func testCurrentMinMax() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(10)
        buf.recordValue(5)
        buf.recordValue(20)
        buf.recordValue(7)

        guard let mm = buf.currentMinMax else {
            XCTFail("Expected min/max")
            return
        }
        XCTAssertEqual(mm.min, 5)
        XCTAssertEqual(mm.max, 20)
    }

    func testMinMaxSingleValue() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(42)
        guard let mm = buf.currentMinMax else {
            XCTFail("Expected min/max")
            return
        }
        XCTAssertEqual(mm.min, 42)
        XCTAssertEqual(mm.max, 42)
    }

    func testMinMaxWithGaps() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(100)
        buf.recordGap()
        buf.recordValue(50)
        buf.recordGap()
        buf.recordValue(75)

        guard let mm = buf.currentMinMax else {
            XCTFail("Expected min/max")
            return
        }
        XCTAssertEqual(mm.min, 50)
        XCTAssertEqual(mm.max, 100)
    }

    // MARK: - Latest value

    func testLatestValue() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(1)
        buf.recordValue(2)
        XCTAssertEqual(buf.latestValue, 2)
        buf.recordGap()
        // Latest value should still be the last real value
        XCTAssertEqual(buf.latestValue, 2)
        buf.recordValue(3)
        XCTAssertEqual(buf.latestValue, 3)
    }

    // MARK: - Reset

    func testReset() {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(1)
        buf.recordValue(2)
        buf.recordGap()
        buf.reset()
        XCTAssertTrue(buf.isEmpty)
        XCTAssertEqual(buf.count, 0)
        XCTAssertNil(buf.latestValue)
        XCTAssertNil(buf.currentMinMax)
    }

    // MARK: - Span

    func testSpan() {
        let buf = MetricsRingBuffer(capacity: 10)
        let t1 = Date(timeIntervalSinceReferenceDate: 0)
        let t2 = Date(timeIntervalSinceReferenceDate: 10)
        let t3 = Date(timeIntervalSinceReferenceDate: 20)

        buf.recordValue(1, timestamp: t1)
        buf.recordValue(2, timestamp: t2)
        buf.recordValue(3, timestamp: t3)

        guard let span = buf.span else {
            XCTFail("Expected span")
            return
        }
        XCTAssertEqual(span.start, t1)
        XCTAssertEqual(span.end, t3)
    }

    func testSpanWithGaps() {
        let buf = MetricsRingBuffer(capacity: 10)
        let t1 = Date(timeIntervalSinceReferenceDate: 0)
        let t2 = Date(timeIntervalSinceReferenceDate: 10)

        buf.recordValue(1, timestamp: t1)
        buf.recordGap(timestamp: t2)

        guard let span = buf.span else {
            XCTFail("Expected span")
            return
        }
        XCTAssertEqual(span.start, t1)
        XCTAssertEqual(span.end, t2)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let buf = MetricsRingBuffer(capacity: 10)
        buf.recordValue(1, timestamp: Date(timeIntervalSinceReferenceDate: 100))
        buf.recordGap(reason: "sleep", timestamp: Date(timeIntervalSinceReferenceDate: 200))
        buf.recordValue(3, timestamp: Date(timeIntervalSinceReferenceDate: 300))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(buf)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode(MetricsRingBuffer.self, from: data)

        XCTAssertEqual(restored.capacity, 10)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.valueSamples.count, 2)
        XCTAssertEqual(restored.samples[1].gapReason, "sleep")
        XCTAssertNil(restored.samples[1].value)
    }

    // MARK: - Thread safety (basic concurrent writes)

    func testConcurrentWrites() {
        let buf = MetricsRingBuffer(capacity: 100)
        let iterations = 500

        let q1 = DispatchQueue(label: "q1")
        let q2 = DispatchQueue(label: "q2")
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            q1.async {
                buf.recordValue(Double(i))
                group.leave()
            }
            group.enter()
            q2.async {
                buf.recordGap(reason: "gap-\(i)")
                group.leave()
            }
        }

        group.wait()

        // Total should not exceed capacity
        XCTAssertLessThanOrEqual(buf.count, 100)

        // Should not crash — if we got here the lock is working
        _ = buf.samples
        _ = buf.valueSamples
        _ = buf.currentMinMax
    }

    // MARK: - Capacity edge cases

    func testCapacityOne() {
        let buf = MetricsRingBuffer(capacity: 1)
        buf.recordValue(1)
        XCTAssertEqual(buf.count, 1)
        buf.recordValue(2)
        XCTAssertEqual(buf.count, 1)
        XCTAssertEqual(buf.latestValue, 2)
    }

    func testCapacityZeroClampedToOne() {
        let buf = MetricsRingBuffer(capacity: 0)
        XCTAssertEqual(buf.capacity, 1)
    }

    func testNegativeCapacityClamped() {
        let buf = MetricsRingBuffer(capacity: -5)
        XCTAssertEqual(buf.capacity, 1)
    }
}

import Foundation
import XCTest
@testable import SymCockpitHistory

final class ReplayCodecTests: XCTestCase {
    private let timestamp = "2026-08-28T10:00:00Z"

    private func event(
        action: String = "click",
        target: [String: HistoryJSONValue] = [
            "bundle_id": .string("com.example.Editor"),
            "role": .string("button"),
            "label": .string("Run")
        ],
        payload: [String: HistoryJSONValue] = [:]
    ) -> CanonicalHistoryEvent {
        var values = payload
        values["target"] = .object(target)
        values["success"] = .bool(true)
        return CanonicalHistoryEvent(
            source: "operate",
            timestamp: timestamp,
            action: action,
            payload: values
        )
    }

    func testCodecRedactsSecretsAndSecureFieldsBeforeEncoding() throws {
        let record = event(payload: [
            "note": .string("authorization: Bearer sk-test-secret-12345"),
            "password": .string("private user content")
        ])

        let data = try DeterministicReplayCodec().encode([record])
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-test-secret-12345"))
        XCTAssertFalse(encoded.contains("private user content"))
        XCTAssertTrue(encoded.contains("<redacted>"))

        let decoded = try DeterministicReplayCodec().decode(data)
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records[0].payload["password"], .string("<redacted>"))
    }

    func testCodecIsDeterministicAndPreservesRecordOrder() throws {
        let first = event(payload: ["z": .integer(1), "a": .string("first")])
        let second = event(action: "scroll", payload: ["a": .string("second"), "z": .integer(2)])
        let reorderedFirst = event(payload: ["a": .string("first"), "z": .integer(1)])
        let reorderedSecond = event(action: "scroll", payload: ["z": .integer(2), "a": .string("second")])
        let codec = DeterministicReplayCodec()

        XCTAssertEqual(try codec.encode([first, second]), try codec.encode([reorderedFirst, reorderedSecond]))
        let decoded = try codec.decode(try codec.encode([first, second]))
        XCTAssertEqual(decoded.records.map(\.action), ["click", "scroll"])
        XCTAssertEqual(decoded.records.map { $0.payload["a"] }, [.string("first"), .string("second")])
    }

    func testCodecRefusesUnsafeAndNonDeterministicRecords() throws {
        let codec = DeterministicReplayCodec()

        XCTAssertThrowsError(try codec.encode([event(action: "type_text")])) { error in
            guard case .unsafeRecord = error as? DeterministicReplayError else {
                return XCTFail("Expected unsafe record, got \(error)")
            }
        }

        let stale = event(target: ["element_id": .string("snapshot-element-42")])
        XCTAssertThrowsError(try codec.encode([stale])) { error in
            guard case .nonDeterministicRecord = error as? DeterministicReplayError else {
                return XCTFail("Expected non-deterministic record, got \(error)")
            }
        }

        XCTAssertThrowsError(try codec.encode([event(action: "unknown_action")])) { error in
            guard case .unsupportedAction = error as? DeterministicReplayError else {
                return XCTFail("Expected unsupported action, got \(error)")
            }
        }
    }

    func testCodecBoundsRecordCountAndEncodedSize() throws {
        let records = [event(), event(action: "scroll")]
        XCTAssertThrowsError(try DeterministicReplayCodec(maximumRecords: 1).encode(records)) { error in
            XCTAssertEqual(error as? DeterministicReplayError, .tooManyRecords(actual: 2, maximum: 1))
        }

        XCTAssertThrowsError(try DeterministicReplayCodec(maximumBytes: 1).encode([event()])) { error in
            guard case .encodedSizeExceeded = error as? DeterministicReplayError else {
                return XCTFail("Expected encoded-size limit, got \(error)")
            }
        }
    }
}

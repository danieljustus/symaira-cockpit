import XCTest
@testable import SymOperateCore

final class DiagnosticTraceTests: XCTestCase {
    func testRecordsAreStableSortedAndRedacted() throws {
        let trace = DiagnosticTrace(records: [
            DiagnosticTraceRecord(sequence: 2, action: "click", outcome: "submitted", fields: ["token": "secret", "label": "Save"]),
            DiagnosticTraceRecord(sequence: 1, action: "focus", outcome: "confirmed")
        ])
        XCTAssertEqual(trace.records.map(\.sequence), [1, 2])
        XCTAssertEqual(trace.records[1].fields["token"], "[REDACTED]")
        XCTAssertEqual(try DiagnosticTrace(records: trace.records).encoded(), try trace.encoded())
    }

    func testEncodedTraceUsesVersionAndSortedKeys() throws {
        let data = try DiagnosticTrace(records: [DiagnosticTraceRecord(sequence: 1, action: "a", outcome: "ok")]).encoded()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"version\":1"))
        XCTAssertLessThan(json.range(of: "\"records\"")!.lowerBound, json.range(of: "\"version\"")!.lowerBound)
    }
}

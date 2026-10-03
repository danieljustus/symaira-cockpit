import XCTest
@testable import SymTuneCore

final class ProcessNameDecodingTests: XCTestCase {
    private func buffer(_ bytes: [UInt8]) -> [CChar] {
        bytes.map { CChar(bitPattern: $0) }
    }

    func testStopsAtFirstNUL() {
        XCTAssertEqual(LibprocProcessSampleSource.decodeNameBuffer(buffer([65, 0, 66])), "A")
    }

    func testUnterminatedBufferIsBounded() {
        XCTAssertEqual(LibprocProcessSampleSource.decodeNameBuffer(buffer([65, 66])), "AB")
        XCTAssertEqual(LibprocProcessSampleSource.decodeNameBuffer([]), "")
        XCTAssertEqual(LibprocProcessSampleSource.decodeNameBuffer([0]), "")
    }

    func testUTF8NameRetainsMultibyteCharacters() {
        XCTAssertEqual(
            LibprocProcessSampleSource.decodeNameBuffer(buffer(Array("プロセス".utf8) + [0, 65])),
            "プロセス"
        )
    }

    func testInvalidUTF8UsesReplacementCharacter() {
        XCTAssertEqual(LibprocProcessSampleSource.decodeNameBuffer(buffer([65, 255, 0])), "A\u{FFFD}")
    }
}

import XCTest
@testable import SymTuneCore

final class SMCParamBlockTests: XCTestCase {

    func testKeyRoundTripsBigEndian() {
        var block = SMCParamBlock()
        block.key = 0xDEADBEEF
        XCTAssertEqual(block.key, 0xDEADBEEF)
        // Big-endian byte layout: DE AD BE EF at bytes 0-3.
        XCTAssertEqual(block.data[0], 0xDE)
        XCTAssertEqual(block.data[1], 0xAD)
        XCTAssertEqual(block.data[2], 0xBE)
        XCTAssertEqual(block.data[3], 0xEF)
    }

    func testKeyInfoSizeAndTypeRoundTrip() {
        var block = SMCParamBlock()
        block.keyInfoDataSize = 4
        block.keyInfoDataType = 0x666C7434 // "flt4"
        XCTAssertEqual(block.keyInfoDataSize, 4)
        XCTAssertEqual(block.keyInfoDataType, 0x666C7434)
    }

    func testKeyInfoAttributes() {
        var block = SMCParamBlock()
        block.keyInfoDataAttributes = 0xAB
        XCTAssertEqual(block.keyInfoDataAttributes, 0xAB)
    }

    func testCopyKeyInfoCopiesTwelveBytes() {
        var source = SMCParamBlock()
        source.keyInfoDataSize = 8
        source.keyInfoDataType = 0x12345678
        source.keyInfoDataAttributes = 0x42
        source.key = 0xFFFFFFFF // outside the 28..<40 window, must NOT copy

        var target = SMCParamBlock()
        target.copyKeyInfo(from: source)

        XCTAssertEqual(target.keyInfoDataSize, 8)
        XCTAssertEqual(target.keyInfoDataType, 0x12345678)
        XCTAssertEqual(target.keyInfoDataAttributes, 0x42)
        XCTAssertEqual(target.key, 0) // untouched
    }

    func testResultStatusAndData8() {
        var block = SMCParamBlock()
        // `result`/`status` are get-only accessors; write the raw bytes.
        block.data[40] = 1
        block.data[41] = 2
        block.data8 = 9
        XCTAssertEqual(block.result, 1)
        XCTAssertEqual(block.status, 2)
        XCTAssertEqual(block.data8, 9)
    }

    func testData32RoundTrip() {
        var block = SMCParamBlock()
        block.data32 = 0x01020304
        XCTAssertEqual(block.data32, 0x01020304)
    }

    func testDataBytesReturnsEmptyForNonPositiveCount() {
        var block = SMCParamBlock()
        block.data[50] = 0xAA
        XCTAssertEqual(block.dataBytes(0), [])
        XCTAssertEqual(block.dataBytes(-3), [])
    }

    func testDataBytesReturnsRequestedSubrange() {
        var block = SMCParamBlock()
        for i in 0..<32 {
            block.data[48 + i] = UInt8(i)
        }
        XCTAssertEqual(block.dataBytes(4), [0, 1, 2, 3])
        XCTAssertEqual(block.dataBytes(32).count, 32)
    }

    func testDataBytesClampsToThirtyTwo() {
        var block = SMCParamBlock()
        block.data[79] = 0xFF
        XCTAssertEqual(block.dataBytes(64).count, 32)
        XCTAssertEqual(block.dataBytes(64).last, 0xFF)
    }
}

import XCTest
@testable import SymTuneCore

/// Drives `HardwareSMCConnection` through its internal `perform` seam,
/// simulating the IOKit transport without real SMC hardware.
final class SMCTransportTests: XCTestCase {

    private let testKey = "TEST"
    private let dataType: UInt32 = 0x666C7434 // "flt4"

    /// A transport script: keyInfo probes (data8 == 9) answer with a valid
    /// 4-byte key-info block; read calls (data8 == 5) answer with `payload`;
    /// write calls (data8 == 6) succeed. Failures can be injected per stage.
    private func makeTransport(
        isOpen: Bool = true,
        failKeyInfo: Bool = false,
        failRead: Bool = false,
        failWrite: Bool = false,
        keyInfoResult: UInt8 = 0,
        readResult: UInt8 = 0,
        payload: [UInt8] = [0x3F, 0x80, 0x00, 0x00],
        onWrite: ((SMCParamBlock) -> Void)? = nil
    ) -> (HardwareSMCConnection, () -> Int) {
        var keyInfoCalls = 0
        let transport: (inout SMCParamBlock, inout SMCParamBlock) -> Bool = { input, output in
            switch input.data8 {
            case 9: // kSMCReadKeyInfo
                keyInfoCalls += 1
                if failKeyInfo { return false }
                output.data[40] = keyInfoResult // `result` is get-only
                output.keyInfoDataSize = 4
                output.keyInfoDataType = self.dataType
                return true
            case 5: // kSMCReadKey
                if failRead { return false }
                output.data[40] = readResult
                for (i, byte) in payload.enumerated() {
                    output.data[48 + i] = byte
                }
                return true
            case 6: // kSMCWriteKey
                if failWrite { return false }
                output.data[40] = 0
                onWrite?(input)
                return true
            default:
                return false
            }
        }
        let connection = HardwareSMCConnection(isOpen: isOpen, perform: transport)
        return (connection, { keyInfoCalls })
    }

    // MARK: - Closed connection

    func testReadReturnsNilWhenConnectionIsClosed() {
        let (connection, _) = makeTransport(isOpen: false)
        XCTAssertNil(connection.readKeyRaw(testKey))
        XCTAssertFalse(connection.writeKeyRaw(testKey, dataType: dataType, bytes: [1, 2, 3, 4]))
    }

    // MARK: - Key info stage

    func testReadReturnsNilWhenKeyInfoTransportFails() {
        let (connection, _) = makeTransport(failKeyInfo: true)
        XCTAssertNil(connection.readKeyRaw(testKey))
    }

    func testReadReturnsNilWhenKeyInfoResultNonZero() {
        let (connection, _) = makeTransport(keyInfoResult: 7)
        XCTAssertNil(connection.readKeyRaw(testKey))
    }

    // MARK: - Read stage

    func testReadReturnsDataAndTypeOnSuccess() {
        let (connection, _) = makeTransport()
        let result = connection.readKeyRaw(testKey)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.dataType, dataType)
        XCTAssertEqual(result?.bytes, [0x3F, 0x80, 0x00, 0x00])
    }

    func testReadReturnsNilWhenReadTransportFails() {
        let (connection, _) = makeTransport(failRead: true)
        XCTAssertNil(connection.readKeyRaw(testKey))
    }

    func testReadReturnsNilWhenReadResultNonZero() {
        let (connection, _) = makeTransport(readResult: 1)
        XCTAssertNil(connection.readKeyRaw(testKey))
    }

    // MARK: - Write stage

    func testWriteReturnsFalseWhenBytesExceedThirtyTwo() {
        let (connection, _) = makeTransport()
        XCTAssertFalse(connection.writeKeyRaw(testKey, dataType: dataType, bytes: [UInt8](repeating: 0, count: 33)))
    }

    func testWriteReturnsFalseWhenTransportFails() {
        let (connection, _) = makeTransport(failWrite: true)
        XCTAssertFalse(connection.writeKeyRaw(testKey, dataType: dataType, bytes: [1, 2, 3, 4]))
    }

    func testWriteReturnsTrueAndSendsBytes() {
        var written: SMCParamBlock?
        let (connection, _) = makeTransport { input in written = input }
        let ok = connection.writeKeyRaw(testKey, dataType: dataType, bytes: [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertTrue(ok)
        XCTAssertEqual(written?.data8, 6) // kSMCWriteKey
        XCTAssertEqual(written?.data32, 4) // dataSize
        XCTAssertEqual(Array(written!.data[48..<52]), [0xAA, 0xBB, 0xCC, 0xDD])
    }

    // MARK: - Key-info caching

    func testKeyInfoIsCachedAcrossReads() {
        let (connection, keyInfoCalls) = makeTransport()
        _ = connection.readKeyRaw(testKey)
        _ = connection.readKeyRaw(testKey)
        _ = connection.readKeyRaw(testKey)
        XCTAssertEqual(keyInfoCalls(), 1)
    }

    func testFailedKeyInfoIsCachedAsAbsent() {
        let (connection, keyInfoCalls) = makeTransport(failKeyInfo: true)
        _ = connection.readKeyRaw(testKey)
        _ = connection.readKeyRaw(testKey)
        // nil is cached too — the probe does not repeat on every call.
        XCTAssertEqual(keyInfoCalls(), 1)
    }
}

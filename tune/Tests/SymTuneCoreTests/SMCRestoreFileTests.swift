import XCTest
@testable import SymTuneCore

/// Tests for the persisted SMC restore path (#231): originals are written to a
/// `0600` state file at capture time, removed on clean restore, and consumed
/// by the next process start so a killed process cannot strand the hardware.
final class SMCRestoreFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-smcrestore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var restoreFile: URL {
        tempDir.appendingPathComponent("smc-restore.json")
    }

    private func ui32(_ value: UInt32) -> FakeSMCKeyResult {
        FakeSMCKeyResult(
            dataType: smcEncodeKey("ui32"),
            bytes: [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        )
    }

    private func ui8(_ value: UInt8) -> FakeSMCKeyResult {
        FakeSMCKeyResult(dataType: smcEncodeKey("ui8 "), bytes: [value])
    }

    private func flt(_ value: Double) -> FakeSMCKeyResult {
        let raw = Float(value).bitPattern
        return FakeSMCKeyResult(
            dataType: smcEncodeKey("flt "),
            bytes: [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        )
    }

    private func makeController(
        connection: FakeSMCConnection,
        batteryExternal: Bool = true
    ) -> TuneController {
        TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: connection),
            batterySource: FakeBatterySource(
                result: batteryExternal
                    ? .success(BatteryProperties(externalConnected: true))
                    : .unavailable
            ),
            dataDir: tempDir
        )
    }

    private func writeRecord(_ record: SMCRestoreRecord) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(record).write(to: restoreFile, options: .atomic)
    }

    // MARK: - File written on override

    func testChargeOverrideWrites0600RestoreFile() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let controller = makeController(connection: conn)
        try controller.applyChargeLimit(percent: 80)

        XCTAssertTrue(FileManager.default.fileExists(atPath: restoreFile.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: restoreFile.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let record = try decoder.decode(SMCRestoreRecord.self, from: Data(contentsOf: restoreFile))
        XCTAssertEqual(record.architecture, SMCRestoreTracker.currentArchitecture)
        XCTAssertEqual(record.chargeKeyFamily, .chte)
        XCTAssertEqual(record.chargeInhibit, false)
        XCTAssertTrue(record.fanOriginals.isEmpty)

        // Clean restore removes the trail.
        controller.restoreAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
    }

    // MARK: - Clean restore removes the file

    func testCleanRestoreRemovesFile() throws {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(0)])
        let controller = makeController(connection: conn)
        try controller.applyChargeLimit(percent: 80)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoreFile.path))

        controller.restoreAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
        XCTAssertTrue(conn.writtenKeys.contains { $0.key == "CHTE" })
    }

    // MARK: - Leftover file consumed on next start

    func testLeftoverChargeStateRestoredOnNextStart() throws {
        // Simulate a killed process: originals captured (inhibit was off),
        // file left behind, hardware still inhibited.
        let record = SMCRestoreRecord(
            architecture: SMCRestoreTracker.currentArchitecture,
            chargeKeyFamily: .chte,
            fanOriginals: [],
            fsBitmask: nil,
            chargeInhibit: false
        )
        try writeRecord(record)

        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        _ = makeController(connection: conn, batteryExternal: false)

        // Startup consumed the file: the inhibit bit is released and the file
        // is gone before any new override could be applied.
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
    }

    func testLeftoverFanOriginalsRestoredOnNextStart() throws {
        #if arch(arm64)
        let record = SMCRestoreRecord(
            architecture: SMCRestoreTracker.currentArchitecture,
            chargeKeyFamily: nil,
            fanOriginals: [FanOriginal(fanIndex: 0, mode: 3, targetRpm: 3000)],
            fsBitmask: nil,
            chargeInhibit: nil
        )
        try writeRecord(record)

        // Fresh process sees the fan still pinned in manual mode.
        let conn = FakeSMCConnection(isOpen: true, keys: [
            "FNum": ui8(1),
            "F0Md": ui8(1),
            "F0Tg": flt(2000)
        ])
        _ = makeController(connection: conn, batteryExternal: false)

        // Original auto mode is written back and the manual test target is not
        // left in place (mode != 1 means no Tg write on the arm64 path).
        XCTAssertEqual(conn.keys["F0Md"]?.bytes, [3])
        XCTAssertEqual(conn.keys["F0Tg"]?.bytes, flt(2000).bytes, "target RPM must stay untouched for non-manual originals")
        XCTAssertEqual(conn.keys["Ftst"]?.bytes, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
        #endif
    }

    // MARK: - Stale file guards

    func testStaleArchitectureFileIsDiscardedNotApplied() throws {
        let record = SMCRestoreRecord(
            architecture: "x86_64",
            chargeKeyFamily: .chte,
            fanOriginals: [],
            fsBitmask: nil,
            chargeInhibit: false
        )
        try writeRecord(record)

        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        _ = makeController(connection: conn, batteryExternal: false)

        // Nothing was written — the file was discarded, not applied.
        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
    }

    func testStaleKeyFamilySkipsChargeRestore() throws {
        let record = SMCRestoreRecord(
            architecture: SMCRestoreTracker.currentArchitecture,
            chargeKeyFamily: .ch0b,
            fanOriginals: [],
            fsBitmask: nil,
            chargeInhibit: false
        )
        try writeRecord(record)

        // Current platform exposes CHTE; the record was captured on CH0B.
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        _ = makeController(connection: conn, batteryExternal: false)

        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1], "charge restore must be skipped on key-family mismatch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
    }

    func testCorruptFileIsDiscarded() throws {
        try Data("not-json".utf8).write(to: restoreFile, options: .atomic)

        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        _ = makeController(connection: conn, batteryExternal: false)

        XCTAssertEqual(conn.keys["CHTE"]?.bytes, [0, 0, 0, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreFile.path))
    }

    func testNoFileNoRestoreNoWrite() {
        let conn = FakeSMCConnection(isOpen: true, keys: ["CHTE": ui32(1)])
        _ = makeController(connection: conn, batteryExternal: false)
        XCTAssertTrue(conn.writtenKeys.isEmpty, "no restore writes without a leftover file")
    }
}

import XCTest
@testable import SymCockpitCore

final class FanSelectionStoreTests: XCTestCase {
    private func makeStore() throws -> FanProfileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return FanProfileStore(url: directory.appendingPathComponent("fan-profile.json"))
    }

    private func writeRaw(_ json: String, to store: FanProfileStore) throws {
        try Data(json.utf8).write(to: store.url)
    }

    // MARK: - Round trip

    func testRoundTripKeepsTheProfileAndTheTarget() throws {
        let store = try makeStore()
        try store.writeSelection(FanSelection(profile: .comfort, coolTargetCelsius: 72))
        XCTAssertEqual(store.readSelection(), FanSelection(profile: .comfort, coolTargetCelsius: 72))
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 72)
        XCTAssertEqual(store.read(), .comfort)
    }

    func testTheFileUsesTheSnakeCaseKey() throws {
        let store = try makeStore()
        try store.writeSelection(FanSelection(profile: .comfort, coolTargetCelsius: 72))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"cool_target_celsius\":72"), text)
    }

    func testNoTargetWritesNoKey() throws {
        let store = try makeStore()
        try store.write(.comfort)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(text.contains("cool_target_celsius"), text)
        XCTAssertNil(store.readSelection().coolTargetCelsius)
    }

    // MARK: - Old format

    func testAFileWithoutTheKeyStillDecodesWithNoTarget() throws {
        let store = try makeStore()
        try writeRaw(#"{"profile":"performance"}"#, to: store)
        XCTAssertEqual(try store.readSelectionStrict(), FanSelection(profile: .performance))
        XCTAssertEqual(try store.readStrict(), .performance)
        XCTAssertEqual(store.read(), .performance)
    }

    func testANullTargetMeansNoTarget() throws {
        let store = try makeStore()
        try writeRaw(#"{"profile":"comfort","cool_target_celsius":null}"#, to: store)
        XCTAssertNil(try store.readSelectionStrict().coolTargetCelsius)
    }

    // MARK: - Clamping on write and on read

    func testAnOutOfRangeTargetIsClampedOnWrite() throws {
        let store = try makeStore()
        try store.writeSelection(FanSelection(profile: .comfort, coolTargetCelsius: 20))
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 50)
        try store.writeCoolTarget(900)
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 85)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.contains("85"), text)
        XCTAssertFalse(text.contains("900"), text)
    }

    func testAHandEditedOutOfRangeTargetIsClampedOnRead() throws {
        let store = try makeStore()
        try writeRaw(#"{"profile":"comfort","cool_target_celsius":1000}"#, to: store)
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 85)
        XCTAssertEqual(store.readSelection().coolTargetCelsius, 85)
        try writeRaw(#"{"profile":"comfort","cool_target_celsius":-40}"#, to: store)
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 50)
        try writeRaw(#"{"profile":"comfort","cool_target_celsius":0}"#, to: store)
        XCTAssertEqual(try store.readSelectionStrict().coolTargetCelsius, 50)
    }

    func testANonFiniteTargetIsNeverWritten() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.writeCoolTarget(.nan))
        XCTAssertNil(try store.readSelectionStrict().coolTargetCelsius)
        XCTAssertNoThrow(try store.writeCoolTarget(.infinity))
        XCTAssertNil(try store.readSelectionStrict().coolTargetCelsius)
    }

    // MARK: - Corrupt files

    func testTheStrictReaderStillThrowsOnCorruptFiles() throws {
        let store = try makeStore()
        for corrupt in [
            "not json",
            "",
            #"{"profile":"turbo"}"#,
            #"{"profile":"comfort","cool_target_celsius":"hot"}"#,
            #"{"cool_target_celsius":70}"#,
        ] {
            try writeRaw(corrupt, to: store)
            XCTAssertThrowsError(try store.readSelectionStrict(), corrupt)
            XCTAssertThrowsError(try store.readStrict(), corrupt)
            XCTAssertEqual(store.readSelection(), .system, "a corrupt file is never an override: \(corrupt)")
            XCTAssertEqual(store.read(), .system)
        }
        try? FileManager.default.removeItem(at: store.url)
        XCTAssertThrowsError(try store.readSelectionStrict())
        XCTAssertEqual(store.readSelection(), .system)
    }

    // MARK: - Writers keep the other half

    func testSelectingAProfileKeepsTheStoredTarget() throws {
        let store = try makeStore()
        try store.writeSelection(FanSelection(profile: .comfort, coolTargetCelsius: 66))
        try store.write(.performance)
        XCTAssertEqual(store.readSelection(), FanSelection(profile: .performance, coolTargetCelsius: 66))
        try store.write(.system)
        try store.write(.comfort)
        XCTAssertEqual(store.readSelection().coolTargetCelsius, 66)
    }

    func testSettingTheTargetKeepsTheProfileAndClearingRemovesIt() throws {
        let store = try makeStore()
        try store.write(.comfort)
        try store.writeCoolTarget(70)
        XCTAssertEqual(store.readSelection(), FanSelection(profile: .comfort, coolTargetCelsius: 70))
        try store.writeCoolTarget(nil)
        XCTAssertEqual(store.readSelection(), FanSelection(profile: .comfort))
    }

    func testSettingTheTargetWithoutAFileLeavesTheDefaultPosition() throws {
        let store = try makeStore()
        try store.writeCoolTarget(70)
        XCTAssertEqual(store.readSelection().profile, .system)
        XCTAssertEqual(store.readSelection().coolTargetCelsius, 70)
    }
}

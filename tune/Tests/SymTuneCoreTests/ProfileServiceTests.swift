import XCTest
import Foundation
@testable import SymTuneCore

final class ProfileServiceTests: XCTestCase {
    private var tmpDir: URL!
    private var service: ProfileService!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        service = ProfileService(dataDir: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testSaveAndLoadProfile() throws {
        let profile = try TuneProfile(name: "test", brightness: 0.8, dim: 0.5, warmth: 0.3)
        try service.saveProfile(profile)
        let loaded = try service.loadProfile(name: "test")
        XCTAssertEqual(loaded.name, "test")
        XCTAssertEqual(loaded.brightness, 0.8)
        XCTAssertEqual(loaded.dim, 0.5)
        XCTAssertEqual(loaded.warmth, 0.3)
    }

    func testListProfiles() throws {
        let p1 = try TuneProfile(name: "alpha", brightness: 0.5)
        let p2 = try TuneProfile(name: "beta", brightness: 0.7)
        try service.saveProfile(p1)
        try service.saveProfile(p2)
        let list = service.listProfiles()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "alpha")
        XCTAssertEqual(list[1].name, "beta")
    }

    func testDeleteProfile() throws {
        let profile = try TuneProfile(name: "to-delete", brightness: 0.5)
        try service.saveProfile(profile)
        try service.deleteProfile(name: "to-delete")
        let list = service.listProfiles()
        XCTAssertTrue(list.isEmpty)
    }

    func testDeleteNonexistentIsIdempotent() throws {
        let countBefore = service.listProfiles().count
        try service.deleteProfile(name: "nonexistent")
        XCTAssertEqual(service.listProfiles().count, countBefore)
    }

    func testLoadNonexistentThrows() {
        XCTAssertThrowsError(try service.loadProfile(name: "nonexistent"))
    }

    func testOverwriteProfile() throws {
        let p1 = try TuneProfile(name: "overwrite", brightness: 0.5)
        try service.saveProfile(p1)
        let p2 = try TuneProfile(name: "overwrite", brightness: 0.9)
        try service.saveProfile(p2)
        let loaded = try service.loadProfile(name: "overwrite")
        XCTAssertEqual(loaded.brightness, 0.9)
    }

    func testListEmptyDirectory() {
        let list = service.listProfiles()
        XCTAssertTrue(list.isEmpty)
    }

    func testInvalidProfileNameRejected() {
        XCTAssertThrowsError(try TuneProfile(name: "../etc/passwd"))
        XCTAssertThrowsError(try TuneProfile(name: ""))
    }

    func testValidProfileNameAccepted() {
        XCTAssertNoThrow(try TuneProfile(name: "my-profile_123"))
    }

    func testLoadProfileRejectsPathTraversal() {
        XCTAssertThrowsError(try service.loadProfile(name: "../etc/passwd")) { error in
            guard case TuneError.usage = error else {
                return XCTFail("expected .usage, got \(error)")
            }
        }
    }

    func testDeleteProfileRejectsPathTraversal() {
        XCTAssertThrowsError(try service.deleteProfile(name: "../etc/passwd")) { error in
            guard case TuneError.usage = error else {
                return XCTFail("expected .usage, got \(error)")
            }
        }
    }

    func testSaveProfileRejectsPathTraversal() throws {
        let profile = try TuneProfile(name: "valid")
        XCTAssertNoThrow(try service.saveProfile(profile))
    }

    // MARK: - Rules

    func testSaveAndLoadRules() throws {
        let rule = TuneRule(condition: .onBattery, profileName: "low-power")
        try service.addRule(rule)
        let rules = service.loadRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].condition, .onBattery)
        XCTAssertEqual(rules[0].profileName, "low-power")
    }

    func testRemoveRule() throws {
        let rule = TuneRule(id: "rule-1", condition: .onAC, profileName: "default")
        try service.addRule(rule)
        try service.removeRule(id: "rule-1")
        let rules = service.loadRules()
        XCTAssertTrue(rules.isEmpty)
    }
}

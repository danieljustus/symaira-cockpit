import XCTest
@testable import SymCockpitHelperKit

final class BundleTrustCheckTests: XCTestCase {
    private let me: UInt32 = 501
    private let app = URL(fileURLWithPath: "/Applications/Symaira Cockpit.app")
    private let helper = URL(fileURLWithPath: "/Applications/Symaira Cockpit.app/Contents/Library/LaunchServices/com.symaira.symtune-helper")

    private func problem(_ table: [String: BundleTrustCheck.Stat]) -> String? {
        BundleTrustCheck.problem(
            appBundle: app, helperExecutable: helper, currentUser: me,
            stat: { table[$0.path] }
        )
    }

    private func ok(owner: UInt32? = nil) -> [String: BundleTrustCheck.Stat] {
        [
            app.path: .init(mode: 0o755, owner: owner ?? me),
            helper.path: .init(mode: 0o755, owner: owner ?? me),
        ]
    }

    func testOwnerWritableOnlyBundleIsAccepted() {
        XCTAssertNil(problem(ok()))
        XCTAssertNil(problem(ok(owner: 0)), "root-owned (an admin install) is fine")
    }

    func testGroupOrOtherWritableAppBundleIsRefused() {
        for mode: UInt16 in [0o775, 0o757, 0o777, 0o770] {
            var table = ok()
            table[app.path] = .init(mode: mode, owner: me)
            XCTAssertNotNil(problem(table), String(mode, radix: 8))
        }
    }

    func testGroupOrOtherWritableHelperIsRefused() {
        var table = ok()
        table[helper.path] = .init(mode: 0o775, owner: me)
        XCTAssertTrue(problem(table)?.contains("writable by other users") ?? false)
    }

    func testForeignOwnerSymlinkAndMissingFilesAreRefused() {
        XCTAssertNotNil(problem(ok(owner: 502)))
        var linked = ok()
        linked[helper.path] = .init(mode: 0o755, owner: me, isSymlink: true)
        XCTAssertNotNil(problem(linked))
        XCTAssertNotNil(problem([app.path: .init(mode: 0o755, owner: me)]), "helper missing")
    }

    func testRealFilesystemModes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trustcheck-\(UUID().uuidString)", isDirectory: true)
        let exe = dir.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data("x".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertNil(BundleTrustCheck.problem(appBundle: dir, helperExecutable: exe))

        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: dir.path)
        XCTAssertNotNil(BundleTrustCheck.problem(appBundle: dir, helperExecutable: exe))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: exe.path)
        XCTAssertNotNil(BundleTrustCheck.problem(appBundle: dir, helperExecutable: exe))
    }
}

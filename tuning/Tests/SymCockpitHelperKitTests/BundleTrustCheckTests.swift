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

    private var chain: [URL] {
        let contents = app.appendingPathComponent("Contents")
        let library = contents.appendingPathComponent("Library")
        return [app, contents, library, library.appendingPathComponent("LaunchServices"), helper]
    }

    private func ok(owner: UInt32? = nil) -> [String: BundleTrustCheck.Stat] {
        Dictionary(uniqueKeysWithValues: chain.map {
            ($0.path, BundleTrustCheck.Stat(mode: 0o755, owner: owner ?? me))
        })
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

    func testEveryDirectoryBetweenTheBundleAndTheHelperIsChecked() {
        for directory in chain.dropFirst().dropLast() {
            var writable = ok()
            writable[directory.path] = .init(mode: 0o777, owner: me)
            XCTAssertTrue(
                problem(writable)?.contains(directory.path) ?? false,
                "writable \(directory.lastPathComponent) must be refused"
            )
            var foreign = ok()
            foreign[directory.path] = .init(mode: 0o755, owner: 502)
            XCTAssertNotNil(problem(foreign), "foreign-owned \(directory.lastPathComponent)")
            var linked = ok()
            linked[directory.path] = .init(mode: 0o755, owner: me, isSymlink: true)
            XCTAssertNotNil(problem(linked), "symlinked \(directory.lastPathComponent)")
            var missing = ok()
            missing[directory.path] = nil
            XCTAssertNotNil(problem(missing), "uninspectable \(directory.lastPathComponent)")
        }
    }

    func testAHelperOutsideTheBundleIsRefused() {
        let outside = URL(fileURLWithPath: "/tmp/com.symaira.symtune-helper")
        XCTAssertNotNil(BundleTrustCheck.problem(
            appBundle: app, helperExecutable: outside, currentUser: me,
            stat: { _ in .init(mode: 0o755, owner: self.me) }
        ))
        XCTAssertNotNil(BundleTrustCheck.problem(
            appBundle: app, helperExecutable: app, currentUser: me,
            stat: { _ in .init(mode: 0o755, owner: self.me) }
        ), "the bundle itself is not a helper")
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

    func testRealNestedDirectoryModes() throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory
            .appendingPathComponent("trustcheck-\(UUID().uuidString).app", isDirectory: true)
        let services = bundle.appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        let exe = services.appendingPathComponent("helper")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        fm.createFile(atPath: exe.path, contents: Data("x".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        for url in [bundle, bundle.appendingPathComponent("Contents"),
                    bundle.appendingPathComponent("Contents/Library"), services, exe] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        XCTAssertNil(BundleTrustCheck.problem(appBundle: bundle, helperExecutable: exe))

        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: services.path)
        let problem = BundleTrustCheck.problem(appBundle: bundle, helperExecutable: exe)
        XCTAssertTrue(problem?.contains("LaunchServices") ?? false, problem ?? "nil")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: services.path)

        // A symlinked directory in the chain is refused as well.
        let real = bundle.appendingPathComponent("Contents/Library/Real", isDirectory: true)
        try fm.moveItem(at: services, to: real)
        try fm.createSymbolicLink(at: services, withDestinationURL: real)
        XCTAssertNotNil(BundleTrustCheck.problem(appBundle: bundle, helperExecutable: exe))
    }
}

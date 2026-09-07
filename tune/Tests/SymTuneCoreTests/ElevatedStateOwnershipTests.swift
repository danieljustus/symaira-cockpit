import Darwin
import Foundation
import XCTest
@testable import SymTuneCore

/// The GUI elevates through `osascript`'s `do shell script … with
/// administrator privileges`, which sets none of `SUDO_UID`/`SUDO_GID`/
/// `SUDO_USER`. The old ownership hooks keyed off exactly those, so on that
/// path the chown was a no-op and the root child left root-owned 0600 files in
/// the user's data directory — after which every unprivileged run failed to
/// write history or a restore record.
final class ElevatedStateOwnershipTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// Running as root with no SUDO_* at all: ownership must still be found,
    /// taken from the directory the state belongs to.
    func testOwnershipComesFromTheDataDirectoryWhenNoSudoEnvironmentExists() throws {
        let dataDir = URL(fileURLWithPath: "/Users/example/.local/share/symtune", isDirectory: true)
        let owner = StateFilePermissions.ownershipToRestore(
            for: dataDir,
            attributesOfPath: { path in
                // Only the user's home exists yet, as on a first run.
                path == "/Users/example" ? (501, 20) : nil
            },
            isRoot: { true },
            sudoOwnership: .some(nil)   // no SUDO_* in the environment
        )

        XCTAssertEqual(owner?.0, 501, "the state must be owned by the user, not root")
        XCTAssertEqual(owner?.1, 20)
    }

    /// The directory's own owner wins when it already exists.
    func testExistingDataDirectoryOwnerIsUsedDirectly() {
        let owner = StateFilePermissions.ownershipToRestore(
            for: URL(fileURLWithPath: "/Users/example/.local/share/symtune", isDirectory: true),
            attributesOfPath: { _ in (501, 20) },
            isRoot: { true },
            sudoOwnership: .some(nil)
        )
        XCTAssertEqual(owner?.0, 501)
    }

    /// The terminal `sudo` path must keep working: every ancestor root-owned
    /// falls back to the sudo environment rather than giving up.
    func testFallsBackToTheSudoEnvironmentWhenEveryAncestorIsRootOwned() {
        let owner = StateFilePermissions.ownershipToRestore(
            for: URL(fileURLWithPath: "/var/root/.local/share/symtune", isDirectory: true),
            attributesOfPath: { _ in (0, 0) },
            isRoot: { true },
            sudoOwnership: .some((502, 21))
        )
        XCTAssertEqual(owner?.0, 502, "sudo ownership remains the fallback")
        XCTAssertEqual(owner?.1, 21)
    }

    /// Unprivileged runs must not chown anything.
    func testNoOwnershipIsRestoredWhenNotRunningAsRoot() {
        let owner = StateFilePermissions.ownershipToRestore(
            for: URL(fileURLWithPath: "/Users/example/.local/share/symtune", isDirectory: true),
            attributesOfPath: { _ in (501, 20) },
            isRoot: { false },
            sudoOwnership: .some((502, 21))
        )
        XCTAssertNil(owner)
    }

    /// End to end on a real directory: the file lands in the passed data
    /// directory and keeps that directory's ownership.
    func testFileIsWrittenIntoThePassedDataDirectoryAndKeepsItsOwner() throws {
        let root = try makeRoot()
        let dataDir = root.appendingPathComponent("share/symtune", isDirectory: true)
        try StateFilePermissions.ensureDirectory(dataDir)

        let file = dataDir.appendingPathComponent("smc-restore.json")
        try Data("{}".utf8).write(to: file)
        StateFilePermissions.applyFilePermissions(at: file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "state lands in the passed directory")

        var dirInfo = stat()
        var fileInfo = stat()
        XCTAssertEqual(stat(dataDir.path, &dirInfo), 0)
        XCTAssertEqual(stat(file.path, &fileInfo), 0)
        XCTAssertEqual(fileInfo.st_uid, dirInfo.st_uid, "the file is owned by the directory's owner")
        XCTAssertNotEqual(fileInfo.st_uid, 0, "and that owner is not root")
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(dirInfo.st_mode & 0o777, 0o700)
    }
}

/// The elevated child is told where to write via `--data-dir`; everything the
/// child then creates must land under that directory rather than under
/// whatever home the privileged shell happens to have.
final class ElevatedDataDirRoutingTests: XCTestCase {
    func testControllerRoutesAllStateThroughThePassedDataDirectory() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let controller = TuneController(
            dataDir: dataDir,
            privilegedFanSet: { _ in },
            privilegeIsRoot: { false }
        )

        XCTAssertEqual(controller.dataDir, dataDir)

        // History is one of the two files the review found the elevated child
        // writing. Write it through a service rooted at the passed directory
        // and read it back through the controller: if the controller reads it,
        // its own history service is rooted there too, not in some other home.
        HistoryService(dataDir: dataDir).logEvent(
            HistoryEvent(
                timestamp: Date(),
                action: "fan.set",
                requestedValue: 0.5,
                clampedValue: 0.5,
                appliedValue: 0.5,
                result: "applied",
                errorReason: nil
            )
        )

        let events = controller.getHistory(limit: 10)
        XCTAssertEqual(events.count, 1, "the controller reads history from the passed data directory")
        XCTAssertEqual(events.first?.action, "fan.set")
    }
}

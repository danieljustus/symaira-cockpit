import Foundation
import XCTest

final class ProfileArgumentE2ETests: XCTestCase {
    func testRejectedArgumentsDoNotMutateProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let binary = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("symcockpit")
        func run(_ arguments: [String], expected: Int32) throws {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["tune", "profile"] + arguments
            process.environment = ["HOME": root.path, "CFFIXED_USER_HOME": root.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let output = Pipe()
            let error = Pipe()
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            let child = ServeChild(process: process, stdin: input.fileHandleForWriting,
                                   stdout: output.fileHandleForReading, stderr: error.fileHandleForReading)
            try child.start()
            defer { child.cleanupIfRunning() }
            XCTAssertTrue(child.waitForExit(timeout: 10))
            XCTAssertEqual(child.exitCode, expected, "\(arguments): \(child.stderrLines())")
        }
        let profile = root.appendingPathComponent(".local/share/symtune/profile-owned.json")
        try run(["save", "owned"], expected: 0)
        let original = try Data(contentsOf: profile)
        try run(["delete", "owned", "--dry-run"], expected: 2)
        XCTAssertEqual(try? Data(contentsOf: profile), original, "invalid delete must preserve exact data")
        try run(["save", "unexpected", "--typo"], expected: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".local/share/symtune/profile-unexpected.json").path))
        try run(["list", "--typo"], expected: 2)
        try run(["save"], expected: 2)
        try run(["list"], expected: 0)
        try run(["delete", "owned"], expected: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }
}

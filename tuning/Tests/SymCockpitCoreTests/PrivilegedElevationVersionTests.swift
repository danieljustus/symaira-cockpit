import Foundation
import SymCockpitHistory
import XCTest
@testable import SymCockpitCore

/// A root-owned `symcockpit` that is trustworthy but older than the app is
/// still the wrong code to run as root (issue #409). These tests drive the
/// version gate through a fake resolver and a fake probe runner: nothing here
/// executes a real binary, prompts for a password, or touches osascript.
final class PrivilegedElevationVersionTests: XCTestCase {
    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(executable: String, arguments: [String], timeout: TimeInterval, environment: [String: String])] = []

        func record(_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ environment: [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((executable, arguments, timeout, environment))
        }
    }

    private let path = "/usr/local/bin/symcockpit"

    private func result(
        stdout: String = "",
        status: Int32 = 0,
        timedOut: Bool = false,
        truncated: Bool = false
    ) -> BoundedProcessResult {
        BoundedProcessResult(
            standardOutput: Data(stdout.utf8),
            standardError: Data(),
            terminationStatus: status,
            timedOut: timedOut,
            truncated: truncated
        )
    }

    private func runner(
        _ outcome: BoundedProcessResult,
        recorder: ProbeRecorder = ProbeRecorder()
    ) -> PrivilegedElevation.VersionProbeRunner {
        { executable, arguments, timeout, environment in
            recorder.record(executable, arguments, timeout, environment)
            return outcome
        }
    }

    private func versionJSON(_ version: String) -> String {
        #"{"families":[],"schema_version":1,"tool":"symcockpit","update":{"status":"skipped","update_available":false},"version":"\#(version)"}"#
    }

    // MARK: gate

    func testMatchingVersionIsElevatable() throws {
        let resolved = try PrivilegedElevation.resolveVerifiedSymCockpit(
            resolve: { path },
            expectedVersion: "0.10.0",
            runner: runner(result(stdout: versionJSON("0.10.0")))
        )
        XCTAssertEqual(resolved, path)
    }

    func testStaleVersionIsRefusedWithBothVersionsAndTheFix() {
        XCTAssertThrowsError(
            try PrivilegedElevation.resolveVerifiedSymCockpit(
                resolve: { path },
                expectedVersion: "0.10.0",
                runner: runner(result(stdout: versionJSON("0.6.1")))
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedElevation.ElevationError,
                .staleExecutable(path: path, found: "0.6.1", expected: "0.10.0")
            )
            let text = (error as? PrivilegedElevation.ElevationError)?.description ?? ""
            XCTAssertTrue(text.contains(path), "names the path")
            XCTAssertTrue(text.contains("0.6.1"), "names the found version")
            XCTAssertTrue(text.contains("0.10.0"), "names the expected version")
            XCTAssertTrue(text.contains("fan helper"), "offers the helper")
            XCTAssertTrue(
                text.contains("sudo install -m 755 -o root -g wheel \"$(brew --prefix)/bin/symcockpit\" \(path)"),
                "gives the exact refresh command"
            )
        }
    }

    func testNewerRootCopyIsAlsoRefused() {
        XCTAssertThrowsError(
            try PrivilegedElevation.requireMatchingVersion(
                path: path,
                expected: "0.10.0",
                runner: runner(result(stdout: versionJSON("0.11.0")))
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedElevation.ElevationError,
                .staleExecutable(path: path, found: "0.11.0", expected: "0.10.0")
            )
        }
    }

    func testUnreadableOutputIsRefusedAsUnverifiable() {
        let garbled: [BoundedProcessResult] = [
            result(stdout: "not json at all"),
            result(stdout: #"{"tool":"symcockpit"}"#),
            result(stdout: #"{"version":""}"#),
            result(stdout: #"{"version":7}"#),
            result(stdout: ""),
            result(stdout: versionJSON("0.10.0"), status: 2),
            result(stdout: versionJSON("0.10.0"), truncated: true),
        ]
        for outcome in garbled {
            XCTAssertThrowsError(
                try PrivilegedElevation.requireMatchingVersion(
                    path: path, expected: "0.10.0", runner: runner(outcome)
                )
            ) { error in
                guard case .unverifiableExecutable(let errorPath, let reason)? =
                    error as? PrivilegedElevation.ElevationError
                else { return XCTFail("expected unverifiableExecutable, got \(error)") }
                XCTAssertEqual(errorPath, path)
                XCTAssertFalse(reason.isEmpty)
            }
        }
    }

    func testProbeTimeoutIsRefusedAsUnverifiable() {
        XCTAssertThrowsError(
            try PrivilegedElevation.requireMatchingVersion(
                path: path, expected: "0.10.0", runner: runner(result(timedOut: true))
            )
        ) { error in
            guard case .unverifiableExecutable(_, let reason)? = error as? PrivilegedElevation.ElevationError else {
                return XCTFail("expected unverifiableExecutable, got \(error)")
            }
            XCTAssertTrue(reason.contains("did not answer"), reason)
            let text = (error as? PrivilegedElevation.ElevationError)?.description ?? ""
            XCTAssertTrue(text.contains("could not be verified"))
            XCTAssertTrue(text.contains("sudo install"))
        }
    }

    func testLaunchFailureIsRefusedAsUnverifiable() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try PrivilegedElevation.requireMatchingVersion(
                path: path,
                expected: "0.10.0",
                runner: { _, _, _, _ in throw Boom() }
            )
        ) { error in
            guard case .unverifiableExecutable? = error as? PrivilegedElevation.ElevationError else {
                return XCTFail("expected unverifiableExecutable, got \(error)")
            }
        }
    }

    func testWithoutAnInjectedExpectedVersionTheCheckIsSkipped() throws {
        let recorder = ProbeRecorder()
        let resolved = try PrivilegedElevation.resolveVerifiedSymCockpit(
            resolve: { path },
            expectedVersion: nil,
            runner: runner(result(stdout: versionJSON("0.6.1")), recorder: recorder)
        )
        XCTAssertEqual(resolved, path)
        XCTAssertTrue(recorder.calls.isEmpty, "nothing is run when there is nothing to compare against")
    }

    func testTrustRefusalsHappenBeforeAnyProbe() {
        let recorder = ProbeRecorder()
        XCTAssertThrowsError(
            try PrivilegedElevation.resolveVerifiedSymCockpit(
                resolve: { throw PrivilegedExecutableError.notOwnedByRoot(path: "/opt/homebrew/bin/symcockpit", owner: "daniel") },
                expectedVersion: "0.10.0",
                runner: runner(result(stdout: versionJSON("0.10.0")), recorder: recorder)
            )
        ) { error in
            guard case .untrustedExecutable? = error as? PrivilegedElevation.ElevationError else {
                return XCTFail("expected untrustedExecutable, got \(error)")
            }
        }
        XCTAssertTrue(recorder.calls.isEmpty, "a binary that failed the root-ownership checks is never executed")
    }

    // MARK: probe invocation

    func testProbeIsBoundedUnprivilegedAndNeverChecksForUpdates() {
        let recorder = ProbeRecorder()
        _ = PrivilegedElevation.probeVersion(
            of: path, runner: runner(result(stdout: versionJSON("0.10.0")), recorder: recorder)
        )
        XCTAssertEqual(recorder.calls.count, 1)
        let call = recorder.calls[0]
        XCTAssertEqual(call.executable, path)
        XCTAssertEqual(call.arguments, ["version", "--json", "--no-update-check"])
        XCTAssertLessThanOrEqual(call.timeout, 5)
        XCTAssertEqual(call.environment["SYMCOCKPIT_CHECK_UPDATES"], "0")
        XCTAssertEqual(call.environment["PATH"], "/usr/bin:/bin", "the caller's PATH does not steer the child")
    }

    func testProbeReadsTheVersionFromARealChildProcess() throws {
        // A throwaway script stands in for the CLI; the real BoundedProcessRunner
        // path (timeout, capture, parse) runs, with no root and no real symcockpit.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symcockpit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("symcockpit")
        try "#!/bin/sh\necho '\(versionJSON("9.9.9"))'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertEqual(PrivilegedElevation.probeVersion(of: script.path), .version("9.9.9"))
    }

    func testProbeTimesOutOnAChildThatNeverAnswers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symcockpit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("symcockpit")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Same runner, shorter budget, so the suite does not wait five seconds.
        let outcome = PrivilegedElevation.probeVersion(of: script.path, runner: { exe, args, _, env in
            try BoundedProcessRunner.run(executable: exe, arguments: args, timeoutSeconds: 0.5, environment: env)
        })
        guard case .unreadable(let reason) = outcome else { return XCTFail("expected unreadable, got \(outcome)") }
        XCTAssertTrue(reason.contains("did not answer"), reason)
    }

    // MARK: expected-version injection

    func testExpectedVersionInjectionRoundTripsAndNormalises() {
        let previous = PrivilegedElevation.expectedVersion
        addTeardownBlock { PrivilegedElevation.setExpectedVersion(previous) }

        PrivilegedElevation.setExpectedVersion(" 0.10.0\n")
        XCTAssertEqual(PrivilegedElevation.expectedVersion, "0.10.0")
        PrivilegedElevation.setExpectedVersion("   ")
        XCTAssertNil(PrivilegedElevation.expectedVersion)
        PrivilegedElevation.setExpectedVersion(nil)
        XCTAssertNil(PrivilegedElevation.expectedVersion)
    }

    // MARK: doctor status

    func testInspectReportsMatchStaleAndUnchecked() {
        let ok = runner(result(stdout: versionJSON("0.10.0")))
        let old = runner(result(stdout: versionJSON("0.6.1")))

        let match = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { path }, expectedVersion: "0.10.0", runner: ok)
        XCTAssertEqual(match.state, .matching)
        XCTAssertTrue(match.usable)
        XCTAssertEqual(match.path, path)
        XCTAssertEqual(match.foundVersion, "0.10.0")

        let stale = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { path }, expectedVersion: "0.10.0", runner: old)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertFalse(stale.usable)
        XCTAssertEqual(stale.foundVersion, "0.6.1")
        XCTAssertTrue(stale.detail.contains("0.6.1") && stale.detail.contains("0.10.0"))
        XCTAssertTrue(stale.detail.contains("sudo install"))

        let unchecked = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { path }, expectedVersion: nil, runner: old)
        XCTAssertEqual(unchecked.state, .unchecked)
        XCTAssertTrue(unchecked.usable)
        XCTAssertEqual(unchecked.foundVersion, "0.6.1")
    }

    func testInspectReportsUnverifiableNotInstalledAndUntrusted() {
        let unverifiable = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { path }, expectedVersion: "0.10.0", runner: runner(result(timedOut: true)))
        XCTAssertEqual(unverifiable.state, .unverifiable)
        XCTAssertFalse(unverifiable.usable)

        let missing = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { throw PrivilegedExecutableError.notFound(executable: "symcockpit") },
            expectedVersion: "0.10.0", runner: runner(result()))
        XCTAssertEqual(missing.state, .notInstalled)
        XCTAssertNil(missing.path)
        XCTAssertFalse(missing.usable)

        let recorder = ProbeRecorder()
        let untrusted = PrivilegedElevation.inspectPrivilegedExecutable(
            resolve: { throw PrivilegedExecutableError.notOwnedByRoot(path: "/opt/homebrew/bin/symcockpit", owner: "daniel") },
            expectedVersion: "0.10.0", runner: runner(result(stdout: versionJSON("0.10.0")), recorder: recorder))
        XCTAssertEqual(untrusted.state, .untrusted)
        XCTAssertTrue(untrusted.detail.contains("daniel"))
        XCTAssertTrue(recorder.calls.isEmpty, "an untrusted binary is never run, not even to read its version")
    }

    func testDoctorCapabilityReportsTheInjectedStatus() {
        let status = PrivilegedElevation.PrivilegedExecutableStatus(
            state: .stale, path: path, foundVersion: "0.6.1", expectedVersion: "0.10.0",
            detail: "Root-owned copy \(path) is 0.6.1, but this release is 0.10.0")
        let controller = TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: FakeSMCConnection(isOpen: false)),
            batterySource: FakeBatterySource(result: .unavailable),
            privilegedExecutableStatus: { status }
        )
        let report = controller.capabilities()
        let capability = report.capabilities.first { $0.id == "fan.privilegedExecutable" }
        XCTAssertNotNil(capability)
        XCTAssertEqual(capability?.available, false)
        XCTAssertEqual(capability?.tier, "core")
        XCTAssertTrue(capability?.detail.contains("[stale]") ?? false)
        XCTAssertTrue(capability?.detail.contains("0.6.1") ?? false)
        XCTAssertTrue(report.recommendations.contains { $0.contains("0.6.1") },
                      "a stale copy is also a recommendation")
    }
}

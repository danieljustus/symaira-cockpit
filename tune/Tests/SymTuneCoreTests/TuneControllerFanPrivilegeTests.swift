import XCTest
@testable import SymTuneCore

private final class FanPrivilegeRecorder: @unchecked Sendable {
    var fanSetFractions: [Double] = []
    var governorURLs: [URL] = []
}

private enum GenericPrivilegeError: Error {
    case failed
}

final class TuneControllerFanPrivilegeTests: XCTestCase {
    private func makeDataDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeController(
        dataDir: URL,
        fanGovernorRunning: @escaping @Sendable () -> Bool = { false },
        privilegedFanSet: (@Sendable (Double) throws -> Void)? = nil,
        privilegedFanGovernor: (@Sendable (URL) throws -> Void)? = nil,
        privilegeIsRoot: @escaping @Sendable () -> Bool = { false },
        fanProfileURL: URL
    ) -> TuneController {
        TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: FakeSMCConnection(isOpen: false)),
            batterySource: FakeBatterySource(result: .unavailable),
            dataDir: dataDir,
            fanGovernorRunning: fanGovernorRunning,
            privilegedFanSet: privilegedFanSet,
            privilegedFanGovernor: privilegedFanGovernor,
            privilegeIsRoot: privilegeIsRoot,
            fanProfileURL: fanProfileURL
        )
    }

    func testApplyFanRetriesThroughInjectedPrivilegeOperation() throws {
        let dataDir = try makeDataDir()
        let profileURL = dataDir.appendingPathComponent("fan-profile.json")
        let recorder = FanPrivilegeRecorder()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanSet: { recorder.fanSetFractions.append($0) },
            fanProfileURL: profileURL
        )

        try controller.applyFan(fraction: 0.5, allowPrivilegeEscalation: true)

        XCTAssertEqual(recorder.fanSetFractions, [0.5])
        XCTAssertEqual(controller.getHistory().last?.action, "fan.set")
        XCTAssertEqual(controller.getHistory().last?.result, "success")
    }

    func testApplyFanMapsInjectedElevationErrorAndRecordsFailure() throws {
        let dataDir = try makeDataDir()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanSet: { _ in
                throw PrivilegedElevation.ElevationError.cancelledByUser
            },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json")
        )

        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5, allowPrivilegeEscalation: true)) { error in
            guard case TuneError.permission(let message) = error else {
                return XCTFail("expected a mapped permission error, got \(error)")
            }
            XCTAssertTrue(message.contains("administrator password"), message)
        }
        XCTAssertEqual(controller.getHistory().last?.result, "failed")
        XCTAssertNil(controller.getHistory().last?.appliedValue)
    }

    func testApplyFanRethrowsNonElevationErrorFromInjectedOperation() throws {
        let dataDir = try makeDataDir()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanSet: { _ in throw GenericPrivilegeError.failed },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json")
        )

        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5, allowPrivilegeEscalation: true)) { error in
            guard case GenericPrivilegeError.failed = error else {
                return XCTFail("expected the injected error, got \(error)")
            }
        }
        XCTAssertEqual(controller.getHistory().last?.action, "fan.set")
        XCTAssertEqual(controller.getHistory().last?.result, "failed")
    }

    func testApplyFanProfileStartsAnInjectedGovernorForAGovernedProfile() throws {
        let dataDir = try makeDataDir()
        let profileURL = dataDir.appendingPathComponent("fan-profile.json")
        let recorder = FanPrivilegeRecorder()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanGovernor: { recorder.governorURLs.append($0) },
            fanProfileURL: profileURL
        )

        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)

        XCTAssertEqual(controller.activeFanProfile, .comfort)
        XCTAssertEqual(recorder.governorURLs, [profileURL])
        XCTAssertEqual(controller.getHistory().last?.result, "success")
    }

    func testApplyFanProfileRollsBackWhenGovernorElevationFails() throws {
        let dataDir = try makeDataDir()
        let profileURL = dataDir.appendingPathComponent("fan-profile.json")
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanGovernor: { _ in
                throw PrivilegedElevation.ElevationError.cancelledByUser
            },
            fanProfileURL: profileURL
        )

        XCTAssertThrowsError(try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)) { error in
            guard case TuneError.permission(let message) = error else {
                return XCTFail("expected a mapped permission error, got \(error)")
            }
            XCTAssertTrue(message.contains("administrator password"), message)
        }
        XCTAssertEqual(controller.activeFanProfile, .system)
        XCTAssertEqual(controller.getHistory().last?.action, "fan.profile.performance")
        XCTAssertEqual(controller.getHistory().last?.result, "failed")
    }

    func testSystemProfileNeverStartsGovernor() throws {
        let dataDir = try makeDataDir()
        let recorder = FanPrivilegeRecorder()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanGovernor: { recorder.governorURLs.append($0) },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json")
        )

        try controller.applyFanProfile(.system, allowPrivilegeEscalation: true)

        XCTAssertTrue(recorder.governorURLs.isEmpty)
        XCTAssertEqual(controller.activeFanProfile, .system)
    }

    func testRunningGovernorNeedsNoSecondElevation() throws {
        let dataDir = try makeDataDir()
        let recorder = FanPrivilegeRecorder()
        let controller = makeController(
            dataDir: dataDir,
            fanGovernorRunning: { true },
            privilegedFanGovernor: { recorder.governorURLs.append($0) },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json")
        )

        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)

        XCTAssertTrue(recorder.governorURLs.isEmpty)
        XCTAssertEqual(controller.activeFanProfile, .performance)
    }

    func testPrivilegeOperationIsNotCalledWhenEscalationIsDisabled() throws {
        let dataDir = try makeDataDir()
        let recorder = FanPrivilegeRecorder()
        let controller = makeController(
            dataDir: dataDir,
            privilegedFanGovernor: { recorder.governorURLs.append($0) },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json")
        )

        try controller.applyFanProfile(.comfort)

        XCTAssertTrue(recorder.governorURLs.isEmpty)
        XCTAssertEqual(controller.activeFanProfile, .comfort)
    }
}

import XCTest
@testable import SymCockpitCore

private final class FakeFanHelper: FanHelperControlling, @unchecked Sendable {
    private let lock = NSLock()
    var state: FanHelperAvailability
    var startError: Error?
    private(set) var started: [FanProfile] = []
    private(set) var stops = 0

    init(_ state: FanHelperAvailability) { self.state = state }

    func availability() -> FanHelperAvailability { state }
    func startGovernor(profile: FanProfile) throws {
        lock.lock(); defer { lock.unlock() }
        if let startError { throw startError }
        started.append(profile)
    }
    func stopGovernor() throws {
        lock.lock(); stops += 1; lock.unlock()
    }
}

private final class GovernorLaunches: @unchecked Sendable {
    var urls: [URL] = []
}

final class TuneControllerFanHelperTests: XCTestCase {
    private func makeDataDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeController(
        helper: (any FanHelperControlling)?,
        launches: GovernorLaunches,
        legacyGovernorRunning: Bool = false,
        isRoot: Bool = false
    ) throws -> TuneController {
        let dataDir = try makeDataDir()
        return TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: FakeSMCConnection(isOpen: false)),
            batterySource: FakeBatterySource(result: .unavailable),
            dataDir: dataDir,
            fanGovernorRunning: { legacyGovernorRunning },
            privilegedFanGovernor: { launches.urls.append($0) },
            privilegeIsRoot: { isRoot },
            fanProfileURL: dataDir.appendingPathComponent("fan-profile.json"),
            fanHelper: helper
        )
    }

    func testWithoutAHelperTheOsascriptGovernorIsStartedAsBefore() throws {
        let launches = GovernorLaunches()
        let controller = try makeController(helper: nil, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertEqual(launches.urls.count, 1)
    }

    func testHelperOffOrUnsignedKeepsTheOsascriptPath() throws {
        for state in [FanHelperAvailability.off, .unavailable(.unsigned), .unavailable(.notBundled),
                      .requiresApproval, .notRegistered] {
            let launches = GovernorLaunches()
            let helper = FakeFanHelper(state)
            let controller = try makeController(helper: helper, launches: launches)
            try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
            XCTAssertEqual(launches.urls.count, 1, "\(state)")
            XCTAssertTrue(helper.started.isEmpty, "\(state)")
        }
    }

    func testEnabledHelperTakesTheFanChangeWithoutAnAdministratorPrompt() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertEqual(helper.started, [.comfort])
        XCTAssertTrue(launches.urls.isEmpty, "no osascript governor may be launched")
        XCTAssertEqual(controller.activeFanProfile, .comfort, "the selection is still persisted")
    }

    func testMovingBetweenPositionsRetargetsTheHelper() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
        XCTAssertEqual(helper.started, [.comfort, .performance])
    }

    func testSelectingSystemStopsTheHelperGovernor() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        try controller.applyFanProfile(.system, allowPrivilegeEscalation: true)
        XCTAssertEqual(helper.stops, 1)
        XCTAssertEqual(controller.activeFanProfile, .system)
    }

    func testHelperFailureFallsBackToTheOsascriptPath() throws {
        struct Unreachable: Error {}
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        helper.startError = Unreachable()
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertEqual(launches.urls.count, 1)
    }

    func testARunningLegacyGovernorIsNotDuplicatedByTheHelper() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(
            helper: helper, launches: launches, legacyGovernorRunning: true
        )
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertTrue(helper.started.isEmpty)
        XCTAssertTrue(launches.urls.isEmpty)
    }

    func testResumeAfterRelaunchReappliesTheStoredProfileOnlyThroughAnEnabledHelper() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.fanProfileStore.write(.performance)
        controller.resumeFanProfileViaHelper()
        XCTAssertEqual(helper.started, [.performance])

        let offHelper = FakeFanHelper(.off)
        let offController = try makeController(helper: offHelper, launches: launches)
        try offController.fanProfileStore.write(.performance)
        offController.resumeFanProfileViaHelper()
        XCTAssertTrue(offHelper.started.isEmpty)
        XCTAssertTrue(launches.urls.isEmpty, "resume must never raise an administrator prompt")
    }

    func testResumeDoesNothingForTheSystemPosition() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        controller.resumeFanProfileViaHelper()
        XCTAssertTrue(helper.started.isEmpty)
    }
}

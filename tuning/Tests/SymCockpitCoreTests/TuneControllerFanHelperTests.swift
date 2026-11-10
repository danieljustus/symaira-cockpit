import XCTest
@testable import SymCockpitCore

private final class FakeFanHelper: FanHelperControlling, @unchecked Sendable {
    private let lock = NSLock()
    var state: FanHelperAvailability
    var startError: Error?
    private(set) var started: [FanProfile] = []
    private(set) var stops = 0
    var status = FanHelperGovernorStatus.idle

    init(_ state: FanHelperAvailability) { self.state = state }

    func governorStatus() -> FanHelperGovernorStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func availability() -> FanHelperAvailability { state }
    func startGovernor(profile: FanProfile) throws {
        lock.lock(); defer { lock.unlock() }
        if let startError { throw startError }
        started.append(profile)
        status = FanHelperGovernorStatus(isGoverning: true, profile: profile)
    }
    func stopGovernor() throws {
        lock.lock(); stops += 1; status = .idle; lock.unlock()
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

    // MARK: - F3: the "is a governor running" check sees the helper

    func testGovernorRunningCheckSeesTheHelperGoverning() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        XCTAssertFalse(controller.isFanGovernorRunning())
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertTrue(controller.isFanGovernorRunning(), "the UI/HUD must not say 'no governor is running'")
        try controller.applyFanProfile(.system, allowPrivilegeEscalation: true)
        XCTAssertFalse(controller.isFanGovernorRunning())
    }

    func testGovernorRunningCheckIsUnchangedWithoutAHelper() throws {
        let launches = GovernorLaunches()
        let plain = try makeController(helper: nil, launches: launches, legacyGovernorRunning: false)
        XCTAssertFalse(plain.isFanGovernorRunning())
        let legacy = try makeController(helper: nil, launches: launches, legacyGovernorRunning: true)
        XCTAssertTrue(legacy.isFanGovernorRunning())
    }

    func testAGoverningHelperIsNotDuplicatedByALegacyGovernorAfterAFailedRetarget() throws {
        struct Unreachable: Error {}
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        helper.startError = Unreachable()
        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
        XCTAssertTrue(launches.urls.isEmpty, "the helper still governs; no osascript governor beside it")
    }

    // MARK: - F2: the stored profile still reaches a helper-driven governor

    func testStoringSystemFromAnotherProcessStopsTheHelperGovernor() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
        // `symcockpit fan profile system` / MCP: only the stored file changes.
        try controller.fanProfileStore.write(.system)
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.stops, 1)
        XCTAssertFalse(controller.isFanGovernorRunning())
        XCTAssertEqual(controller.activeFanProfile, .system)
    }

    func testStoringAnotherPositionFromAnotherProcessRetargetsTheHelper() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        try controller.fanProfileStore.write(.performance)
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.started, [.comfort, .performance])
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.started.count, 2, "already in line: nothing more to send")
    }

    func testReconcileNeverStartsAGovernorTheHelperIsNotRunning() throws {
        let launches = GovernorLaunches()
        let helper = FakeFanHelper(.enabled)
        let controller = try makeController(helper: helper, launches: launches)
        try controller.fanProfileStore.write(.performance) // e.g. set by the CLI
        controller.reconcileFanProfileWithHelper()
        XCTAssertTrue(helper.started.isEmpty)
        XCTAssertEqual(helper.stops, 0)
        XCTAssertTrue(launches.urls.isEmpty)
    }

    func testReconcileIsANoOpWithoutAHelper() throws {
        let controller = try makeController(helper: nil, launches: GovernorLaunches())
        controller.reconcileFanProfileWithHelper()
    }
}

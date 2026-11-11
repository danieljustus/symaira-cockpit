import XCTest
@testable import SymCockpitCore

private final class CoolTargetFakeHelper: FanHelperControlling, @unchecked Sendable {
    private let lock = NSLock()
    var state: FanHelperAvailability
    private(set) var started: [(profile: FanProfile, target: Double?)] = []
    private(set) var settingsOpened = 0
    private var status = FanHelperGovernorStatus.idle

    init(_ state: FanHelperAvailability) { self.state = state }

    func availability() -> FanHelperAvailability { state }
    func startGovernor(profile: FanProfile, coolTarget: Double?) throws {
        lock.lock(); defer { lock.unlock() }
        started.append((profile, coolTarget))
        status = FanHelperGovernorStatus(isGoverning: true, profile: profile, coolTarget: coolTarget)
    }
    func stopGovernor() throws {
        lock.lock(); status = .idle; lock.unlock()
    }
    func governorStatus() -> FanHelperGovernorStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }
    func openSystemSettings() {
        lock.lock(); settingsOpened += 1; lock.unlock()
    }
}

final class TuneControllerCoolTargetTests: XCTestCase {
    private func makeController(
        helper: (any FanHelperControlling)?,
        legacyGovernorRunning: Bool = false,
        isRoot: Bool = false
    ) throws -> TuneController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-cool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TuneController(
            config: TuneConfig(),
            displayWrite: MockDisplayWriteService(),
            smcService: SMCService(connection: FakeSMCConnection(isOpen: false)),
            batterySource: FakeBatterySource(result: .unavailable),
            dataDir: directory,
            fanGovernorRunning: { legacyGovernorRunning },
            privilegedFanGovernor: { _ in },
            privilegeIsRoot: { isRoot },
            fanProfileURL: directory.appendingPathComponent("fan-profile.json"),
            fanHelper: helper
        )
    }

    // MARK: - Rights navigation through the controller

    func testSelectionActionFollowsTheHelperAvailability() throws {
        let expectations: [(FanHelperAvailability, FanSelectionAction)] = [
            (.off, .openHelperPreferences),
            (.notRegistered, .openHelperPreferences),
            (.requiresApproval, .openSystemSettingsApproval),
            (.enabled, .proceed(.helper)),
            (.unavailable(.unsigned), .proceed(.osascript)),
            (.unavailable(.notBundled), .proceed(.osascript)),
        ]
        for (state, expected) in expectations {
            let controller = try makeController(helper: CoolTargetFakeHelper(state))
            XCTAssertEqual(controller.fanSelectionAction(for: .comfort), expected, "\(state)")
            XCTAssertEqual(controller.fanSelectionAction(for: .performance), expected, "\(state)")
        }
    }

    func testSelectionActionNeverNavigatesForStandardOrWithoutAHelper() throws {
        for state in [FanHelperAvailability.off, .notRegistered, .requiresApproval] {
            let controller = try makeController(helper: CoolTargetFakeHelper(state))
            XCTAssertEqual(
                controller.fanSelectionAction(for: .system),
                .proceed(FanHelperRouting.route(for: state))
            )
        }
        let plain = try makeController(helper: nil)
        XCTAssertEqual(plain.fanSelectionAction(for: .comfort), .proceed(.osascript))
    }

    func testSelectionActionDoesNotNavigateWhileAGovernorAlreadyRuns() throws {
        let controller = try makeController(helper: CoolTargetFakeHelper(.off), legacyGovernorRunning: true)
        XCTAssertEqual(controller.fanSelectionAction(for: .performance), .proceed(.osascript))
    }

    func testSelectionActionIsInertAsRoot() throws {
        let controller = try makeController(helper: CoolTargetFakeHelper(.off), isRoot: true)
        XCTAssertEqual(controller.fanSelectionAction(for: .comfort), .proceed(.osascript))
    }

    func testAskingForTheActionWritesNothing() throws {
        let controller = try makeController(helper: CoolTargetFakeHelper(.off))
        _ = controller.fanSelectionAction(for: .comfort)
        XCTAssertEqual(controller.activeFanProfile, .system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.fanProfileStore.url.path))
    }

    func testApprovalSettingsAreOpenedThroughTheHelper() throws {
        let helper = CoolTargetFakeHelper(.requiresApproval)
        let controller = try makeController(helper: helper)
        controller.openFanHelperApprovalSettings()
        XCTAssertEqual(helper.settingsOpened, 1)
        // Without a helper this is a harmless no-op.
        try makeController(helper: nil).openFanHelperApprovalSettings()
    }

    // MARK: - Setting the target

    func testSettingTheTargetStoresItClampedAndKeepsTheProfile() throws {
        let controller = try makeController(helper: nil)
        try controller.fanProfileStore.write(.comfort)
        try controller.setFanCoolTarget(72)
        XCTAssertEqual(controller.activeFanSelection, FanSelection(profile: .comfort, coolTargetCelsius: 72))
        try controller.setFanCoolTarget(10)
        XCTAssertEqual(controller.activeFanSelection.coolTargetCelsius, 50)
        try controller.setFanCoolTarget(1000)
        XCTAssertEqual(controller.activeFanSelection.coolTargetCelsius, 85)
        try controller.setFanCoolTarget(nil)
        XCTAssertNil(controller.activeFanSelection.coolTargetCelsius)
        XCTAssertEqual(controller.activeFanProfile, .comfort)
    }

    func testANonFiniteTargetIsRefused() throws {
        let controller = try makeController(helper: nil)
        XCTAssertThrowsError(try controller.setFanCoolTarget(.nan))
        XCTAssertThrowsError(try controller.setFanCoolTarget(.infinity))
        XCTAssertNil(controller.activeFanSelection.coolTargetCelsius)
    }

    func testSettingTheTargetNeverStartsAGovernor() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.fanProfileStore.write(.comfort)
        try controller.setFanCoolTarget(70)
        XCTAssertTrue(helper.started.isEmpty, "only the user's position change starts a governor")
    }

    // MARK: - Helper retargeting

    func testTheStoredTargetReachesTheHelperOnStart() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.setFanCoolTarget(68)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        XCTAssertEqual(helper.started.map(\.profile), [.comfort])
        XCTAssertEqual(helper.started.map(\.target), [68])
    }

    func testMaxStartsTheHelperWithoutATarget() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.setFanCoolTarget(68)
        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
        XCTAssertEqual(helper.started.map(\.profile), [.performance])
        XCTAssertEqual(helper.started.first?.target, nil)
    }

    func testChangingOnlyTheTargetRetargetsARunningHelper() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        try controller.setFanCoolTarget(70)
        XCTAssertEqual(helper.started.map(\.profile), [.comfort, .comfort])
        XCTAssertEqual(helper.started.last?.target, 70)
        // Already in line: the next heartbeat reconcile sends nothing.
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.started.count, 2)
        try controller.setFanCoolTarget(60)
        XCTAssertEqual(helper.started.last?.target, 60)
        try controller.setFanCoolTarget(nil)
        XCTAssertNil(helper.started.last?.target)
        XCTAssertEqual(helper.started.count, 4)
    }

    func testATargetChangeFromAnotherProcessIsReconciled() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.applyFanProfile(.comfort, allowPrivilegeEscalation: true)
        // `symcockpit fan target 65` writes only the file.
        try controller.fanProfileStore.writeCoolTarget(65)
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.started.last?.target, 65)
        XCTAssertEqual(helper.started.count, 2)
    }

    func testATargetChangeWhileOnMaxDoesNotDisturbTheHelper() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.applyFanProfile(.performance, allowPrivilegeEscalation: true)
        try controller.setFanCoolTarget(70)
        controller.reconcileFanProfileWithHelper()
        XCTAssertEqual(helper.started.count, 1, "the target does not apply to Max")
    }

    func testResumeAfterRelaunchCarriesTheTarget() throws {
        let helper = CoolTargetFakeHelper(.enabled)
        let controller = try makeController(helper: helper)
        try controller.fanProfileStore.writeSelection(FanSelection(profile: .comfort, coolTargetCelsius: 64))
        controller.resumeFanProfileViaHelper()
        XCTAssertEqual(helper.started.last?.profile, .comfort)
        XCTAssertEqual(helper.started.last?.target, 64)
    }
}

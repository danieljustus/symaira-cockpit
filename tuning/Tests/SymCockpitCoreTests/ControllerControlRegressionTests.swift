import XCTest
@testable import SymCockpitCore

/// Controller behavior only: no real display, SMC or power writes.
final class ControllerControlRegressionTests: XCTestCase {
    private var directory: URL!
    private var display: MockDisplayWriteService!
    private var controller: TuneController!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        display = MockDisplayWriteService()
        controller = TuneController(
            displayWrite: display,
            smcService: SMCService(connection: FakeSMCConnection(isOpen: false)),
            batterySource: FakeBatterySource(result: .unavailable),
            dataDir: directory,
            keepAwakeSource: FakePowerAssertionSource()
        )
    }

    override func tearDownWithError() throws {
        controller = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRestoreClearsDimAndWarmthAndAllowsAnotherOverride() throws {
        try controller.applyDim(0.4)
        try controller.applyWarmth(0.6)
        try controller.applyBuiltinBrightness(0.8)
        controller.restoreAll()
        XCTAssertEqual(controller.getDimLevel(), 1)
        XCTAssertEqual(controller.getWarmthLevel(), 0)
        XCTAssertNil(controller.activeOverrides().dim)
        XCTAssertNil(controller.activeOverrides().warmth)
        XCTAssertNil(controller.activeOverrides().brightness)
        XCTAssertEqual(display.lastSetBrightness, 0.5)
        try controller.applyWarmth(0.3)
        controller.restoreAll()
        XCTAssertEqual(controller.getWarmthLevel(), 0)
    }

    func testRejectedDisplayWritesDoNotBecomeActiveOverrides() throws {
        display.setBuiltinBrightnessError = TuneError.failed("brightness refused")
        display.applyWarmthError = TuneError.failed("warmth refused")
        display.applyExtendedBrightnessError = TuneError.failed("EDR refused")
        XCTAssertThrowsError(try controller.applyBuiltinBrightness(0.8))
        XCTAssertThrowsError(try controller.applyWarmth(0.6))
        XCTAssertThrowsError(try controller.applyExtendedBrightness(1.3))
        let overrides = controller.activeOverrides()
        XCTAssertNil(overrides.brightness)
        XCTAssertNil(overrides.warmth)
        XCTAssertNil(overrides.edrBrightness)
        XCTAssertEqual(controller.getWarmthLevel(), 0)
    }

    func testRejectedDisplayUpdatesKeepLastSuccessfulValues() throws {
        try controller.applyWarmth(0.2)
        try controller.applyExtendedBrightness(1.1)
        display.applyWarmthError = TuneError.failed("warmth refused")
        display.applyExtendedBrightnessError = TuneError.failed("EDR refused")
        XCTAssertThrowsError(try controller.applyWarmth(0.8))
        XCTAssertThrowsError(try controller.applyExtendedBrightness(1.5))
        XCTAssertEqual(controller.getWarmthLevel(), 0.2, accuracy: 0.0001)
        XCTAssertEqual(controller.activeOverrides().edrBrightness, 1.1)
    }

    func testNonFiniteRequestsAreRejectedBeforeAnyWrite() {
        let writes: [(String, (Double) throws -> Void)] = [
            ("brightness", controller.applyBuiltinBrightness),
            ("warmth", controller.applyWarmth),
            ("dim", controller.applyDim),
            ("EDR", controller.applyExtendedBrightness),
            ("fan", { try self.controller.applyFan(fraction: $0) }),
        ]
        for (name, write) in writes {
            for value in [Double.nan, .infinity, -.infinity] {
                XCTAssertThrowsError(try write(value), name) { error in
                    guard case TuneError.usage = error else {
                        return XCTFail("\(name): expected usage error, got \(error)")
                    }
                }
            }
        }
        XCTAssertNil(display.lastSetBrightness)
        XCTAssertNil(display.lastWarmth)
        XCTAssertNil(display.lastExtendedBrightness)
        XCTAssertEqual(display.dimLevel, 1)
    }

    func testSessionKeepAwakeIsIncludedInActiveState() throws {
        XCTAssertFalse(controller.isKeepAwakeActive())
        try controller.beginKeepAwakeSession(duration: nil)
        XCTAssertTrue(controller.isKeepAwakeActive())
        controller.endKeepAwakeSession()
        XCTAssertFalse(controller.isKeepAwakeActive())
    }

    func testLowLevelKeepAwakeUsesInjectedPowerSource() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 817)
        let subject = TuneController(displayWrite: display, dataDir: directory, keepAwakeSource: source)
        let token = try subject.beginKeepAwake(reason: "injected", preventDisplaySleep: true)
        XCTAssertEqual(token.id, 817)
        XCTAssertEqual(source.createCount, 1)
        XCTAssertEqual(source.lastCreatedType, .preventDisplaySleep)
        subject.endKeepAwake(token)
        XCTAssertEqual(source.releaseAssertions.first, 817)
        XCTAssertFalse(subject.isKeepAwakeActive())
    }

    func testInvalidDurationsAreRejectedBeforePowerAssertion() throws {
        let source = FakePowerAssertionSource()
        let coordinator = KeepAwakeCoordinator(source: source)
        XCTAssertThrowsError(try coordinator.begin(duration: -1, preventDisplaySleep: false, reason: "invalid"))
        XCTAssertFalse(coordinator.status().active)
        XCTAssertEqual(source.createCount, 0)
        for text in ["nan", "inf", "-inf", "-1", "1e309"] {
            XCTAssertThrowsError(try AwakeOptions.parseOptions(["--seconds", text]), text)
        }
        for text in ["nan", "inf", "-1s", "0s", "1e308h"] {
            XCTAssertThrowsError(try StatusOptions.parseOptions(["--watch", "--interval", text]), text)
        }
    }
}

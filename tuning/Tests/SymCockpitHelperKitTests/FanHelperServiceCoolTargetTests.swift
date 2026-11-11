import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

/// The XPC boundary for the Cool target. The helper is root and must not trust
/// the app's number blindly. Fakes only: no XPC, no root, no IOKit.
final class FanHelperServiceCoolTargetTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _selections: [FanSelection] = []
        var selections: [FanSelection] { lock.lock(); defer { lock.unlock() }; return _selections }
        func runner() -> FanHelperEngine.GovernorRunner {
            { [self] selectionProvider, shouldContinue, sleep in
                while shouldContinue() {
                    let selection = selectionProvider()
                    lock.lock()
                    if _selections.last != selection { _selections.append(selection) }
                    lock.unlock()
                    sleep(0.02)
                }
            }
        }
    }

    private func makeService() -> (FanHelperService, FanHelperEngine, Recorder) {
        let recorder = Recorder()
        let engine = FanHelperEngine(
            watchdog: HeartbeatWatchdog(timeout: 7, clock: { 1_000_000 }),
            sleepSlice: 0.005, runner: recorder.runner()
        )
        return (FanHelperService(engine: engine), engine, recorder)
    }

    private func start(
        _ service: FanHelperService, profile: String, target: NSNumber?
    ) -> String?? {
        var answer: String??
        service.startGovernor(profile: profile, coolTargetCelsius: target) { answer = .some($0) }
        return answer
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    // MARK: - Decoding

    func testDecodeCoolTarget() {
        typealias D = FanHelperService.CoolTargetDecoding
        XCTAssertEqual(FanHelperService.decodeCoolTarget(nil), D.none)
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: 70.0)), D.value(70))
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: 70)), D.value(70))
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: 20.0)), D.value(50), "clamped up")
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: 1e9)), D.value(85), "clamped down")
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: -5.0)), D.value(50))
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: Double.nan)), D.malformed)
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: Double.infinity)), D.malformed)
        XCTAssertEqual(FanHelperService.decodeCoolTarget(NSNumber(value: -Double.infinity)), D.malformed)
    }

    // MARK: - startGovernor

    func testAValidTargetReachesTheGovernor() {
        let (service, engine, recorder) = makeService()
        XCTAssertEqual(start(service, profile: "comfort", target: NSNumber(value: 68.0)), .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections == [FanSelection(profile: .comfort, coolTargetCelsius: 68)] })
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testAnOutOfRangeTargetIsClampedBeforeTheGovernorSeesIt() {
        let (service, engine, recorder) = makeService()
        XCTAssertEqual(start(service, profile: "comfort", target: NSNumber(value: 500.0)), .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections.last?.coolTargetCelsius == 85 })
        XCTAssertEqual(start(service, profile: "comfort", target: NSNumber(value: 1.0)), .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections.last?.coolTargetCelsius == 50 })
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testAMalformedTargetIsRefusedAndStartsNothing() {
        let (service, engine, recorder) = makeService()
        for bad in [Double.nan, .infinity, -.infinity] {
            let answer = start(service, profile: "comfort", target: NSNumber(value: bad))
            XCTAssertEqual(answer, .some("invalid Cool target"))
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(recorder.selections.isEmpty)
        XCTAssertFalse(engine.snapshot.isGoverning, "a refused request must not leave a governor running")
    }

    func testAMalformedTargetDoesNotDisturbARunningGovernor() {
        let (service, engine, recorder) = makeService()
        XCTAssertEqual(start(service, profile: "comfort", target: NSNumber(value: 70.0)), .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections.count == 1 })
        XCTAssertEqual(start(service, profile: "comfort", target: NSNumber(value: Double.nan)), .some("invalid Cool target"))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(recorder.selections, [FanSelection(profile: .comfort, coolTargetCelsius: 70)])
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testNoTargetMeansTodaysBehaviour() {
        let (service, engine, recorder) = makeService()
        XCTAssertEqual(start(service, profile: "performance", target: nil), .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections == [FanSelection(profile: .performance)] })
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testTheOriginalSelectorStartsAGovernorWithoutATarget() {
        let (service, engine, recorder) = makeService()
        var answer: String??
        service.startGovernor(profile: "comfort") { answer = .some($0) }
        XCTAssertEqual(answer, .some(nil))
        XCTAssertTrue(waitUntil { recorder.selections == [FanSelection(profile: .comfort)] })
        XCTAssertNil(engine.snapshot.coolTarget)
        engine.stop(reason: .requested)
        XCTAssertTrue(engine.waitUntilIdle(timeout: 2))
    }

    func testTheOriginalSelectorStillRefusesAnUnknownProfile() {
        let (service, _, recorder) = makeService()
        var answer: String??
        service.startGovernor(profile: "turbo") { answer = .some($0) }
        XCTAssertEqual(answer, .some("unknown fan profile"))
        XCTAssertTrue(recorder.selections.isEmpty)
    }

    /// The wire contract an older running helper and a newer app both rely on:
    /// the 0.10.x selectors must stay in the protocol next to the new one.
    func testTheProtocolKeepsTheOriginalSelectorsNextToTheNewOne() {
        let proto = NSProtocolFromString(NSStringFromProtocol(FanHelperXPCProtocol.self))
        XCTAssertNotNil(proto)
        for name in [
            "startGovernorWithProfile:reply:", "startGovernorWithProfile:coolTargetCelsius:reply:",
            "heartbeatWithReply:", "stopGovernorWithReply:", "statusWithReply:",
        ] {
            let description = protocol_getMethodDescription(
                try! XCTUnwrap(proto), NSSelectorFromString(name), true, true
            )
            XCTAssertNotNil(description.name, "\(name) must stay exported")
        }
    }

    func testAnUnknownProfileIsStillRefused() {
        let (service, _, recorder) = makeService()
        XCTAssertEqual(start(service, profile: "turbo", target: NSNumber(value: 70.0)), .some("unknown fan profile"))
        XCTAssertTrue(recorder.selections.isEmpty)
    }
}

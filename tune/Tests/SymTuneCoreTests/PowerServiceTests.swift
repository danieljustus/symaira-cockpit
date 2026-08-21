import XCTest
@testable import SymTuneCore

final class PowerServiceTests: XCTestCase {
    func testBeginCreatesSystemSleepAssertion() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 7)
        let service = PowerService(source: source)
        let token = try service.begin(reason: "test", preventDisplaySleep: false)

        XCTAssertEqual(token.id, 7)
    }

    func testBeginCreatesDisplaySleepAssertion() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 8)
        let service = PowerService(source: source)
        let token = try service.begin(reason: "test", preventDisplaySleep: true)

        XCTAssertEqual(token.id, 8)
    }

    func testBeginFailureThrowsFailed() {
        let source = FakePowerAssertionSource()
        source.shouldFailCreate = true
        let service = PowerService(source: source)

        XCTAssertThrowsError(try service.begin(reason: "test", preventDisplaySleep: false)) { error in
            guard case TuneError.failed = error else {
                return XCTFail("expected .failed, got \(error)")
            }
        }
    }

    func testEndReleasesAssertion() {
        let source = FakePowerAssertionSource(nextAssertionID: 9)
        let service = PowerService(source: source)
        let token = KeepAwakeToken(id: IOPMAssertionID(9))
        service.end(token)

        XCTAssertEqual(source.releaseAssertions, [9])
    }
}

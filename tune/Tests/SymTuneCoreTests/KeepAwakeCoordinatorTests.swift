import XCTest
@testable import SymTuneCore

// MARK: - KeepAwakeCoordinator tests
//
// Covers: begin/end/status/double-start/double-end/expiry, all without real IOKit.

final class KeepAwakeCoordinatorTests: XCTestCase {

    // MARK: - Begin

    func testBeginReturnsActiveSession() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 1)
        let coordinator = KeepAwakeCoordinator(source: source)
        let session = try coordinator.begin(
            duration: nil,
            preventDisplaySleep: false,
            reason: "test"
        )
        XCTAssertTrue(session.active)
        XCTAssertFalse(session.preventDisplaySleep)
        XCTAssertEqual(session.reason, "test")
        XCTAssertNil(session.expiresAt)
    }

    func testBeginWithDurationSetsExpiry() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 2)
        let coordinator = KeepAwakeCoordinator(source: source)
        let session = try coordinator.begin(
            duration: 60,
            preventDisplaySleep: true,
            reason: "timed"
        )
        XCTAssertTrue(session.active)
        XCTAssertTrue(session.preventDisplaySleep)
        XCTAssertNotNil(session.expiresAt)
        // expiresAt should be ~60 seconds from now
        let diff = session.expiresAt!.timeIntervalSinceNow
        XCTAssertGreaterThan(diff, 50)
        XCTAssertLessThan(diff, 70)
    }

    func testBeginCreatesCorrectAssertionType() throws {
        // System sleep
        let source1 = FakePowerAssertionSource(nextAssertionID: 10)
        let c1 = KeepAwakeCoordinator(source: source1)
        _ = try c1.begin(duration: nil, preventDisplaySleep: false, reason: "sys")
        XCTAssertEqual(source1.lastCreatedType, .preventSystemSleep)

        // Display sleep
        let source2 = FakePowerAssertionSource(nextAssertionID: 20)
        let c2 = KeepAwakeCoordinator(source: source2)
        _ = try c2.begin(duration: nil, preventDisplaySleep: true, reason: "disp")
        XCTAssertEqual(source2.lastCreatedType, .preventDisplaySleep)
    }

    // MARK: - Double start (idempotent)

    func testDoubleStartReturnsExistingSession() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 3)
        let coordinator = KeepAwakeCoordinator(source: source)
        let first = try coordinator.begin(
            duration: nil,
            preventDisplaySleep: false,
            reason: "first"
        )
        let second = try coordinator.begin(
            duration: 60,
            preventDisplaySleep: true,
            reason: "second"
        )
        // Second call should return the existing session unchanged.
        XCTAssertEqual(first.active, second.active)
        XCTAssertEqual(first.preventDisplaySleep, second.preventDisplaySleep)
        XCTAssertEqual(first.reason, second.reason)
        // Only one assertion was created.
        XCTAssertEqual(source.createCount, 1)
    }

    // MARK: - End

    func testEndReleasesSession() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 4)
        let coordinator = KeepAwakeCoordinator(source: source)
        _ = try coordinator.begin(
            duration: nil,
            preventDisplaySleep: false,
            reason: "end-me"
        )
        XCTAssertTrue(coordinator.status().active)

        coordinator.end()
        XCTAssertFalse(coordinator.status().active)
        XCTAssertEqual(source.releaseAssertions, [4],
                       "assertion ID 4 should have been released")
    }

    func testDoubleEndIsIdempotent() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 5)
        let coordinator = KeepAwakeCoordinator(source: source)
        _ = try coordinator.begin(duration: nil, preventDisplaySleep: false, reason: "idem")
        coordinator.end()
        coordinator.end() // second end — no crash, no extra release
        XCTAssertFalse(coordinator.status().active)
        // Only one release call
        XCTAssertEqual(source.releaseAssertions.count, 1)
    }

    // MARK: - Status

    func testStatusReturnsInactiveBeforeBegin() {
        let source = FakePowerAssertionSource()
        let coordinator = KeepAwakeCoordinator(source: source)
        let status = coordinator.status()
        XCTAssertFalse(status.active)
    }

    func testStatusReflectsActiveState() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 6)
        let coordinator = KeepAwakeCoordinator(source: source)
        _ = try coordinator.begin(duration: 120, preventDisplaySleep: true, reason: "stat")
        let status = coordinator.status()
        XCTAssertTrue(status.active)
        XCTAssertTrue(status.preventDisplaySleep)
        XCTAssertEqual(status.reason, "stat")
        XCTAssertNotNil(status.expiresAt)
    }

    // MARK: - Expiry

    func testExpiryReleasesAutomatically() throws {
        let source = FakePowerAssertionSource(nextAssertionID: 7)
        let coordinator = KeepAwakeCoordinator(source: source)

        // Use a very short duration so the test doesn't take forever.
        _ = try coordinator.begin(
            duration: 0.1,
            preventDisplaySleep: false,
            reason: "short"
        )
        XCTAssertTrue(coordinator.status().active)

        // Wait for expiry.
        let exp = expectation(description: "expiry")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // Session should now be inactive.
        let status = coordinator.status()
        XCTAssertFalse(status.active, "session should auto-expire after 0.1s")
        // The assertion should have been released.
        XCTAssertTrue(source.releaseAssertions.contains(7),
                      "assertion ID 7 should have been released on expiry")
    }

    // MARK: - Begin failure

    func testBeginFailureThrowsAndLeavesInactive() {
        let source = FakePowerAssertionSource()
        source.shouldFailCreate = true
        let coordinator = KeepAwakeCoordinator(source: source)
        XCTAssertThrowsError(try coordinator.begin(
            duration: nil,
            preventDisplaySleep: false,
            reason: "fail"
        ))
        XCTAssertFalse(coordinator.status().active)
    }
}

// MARK: - KeepAwakeSession model tests

final class KeepAwakeSessionTests: XCTestCase {

    func testInactiveConvenience() {
        let s = KeepAwakeSession.inactive
        XCTAssertFalse(s.active)
        XCTAssertFalse(s.preventDisplaySleep)
        XCTAssertNil(s.expiresAt)
        XCTAssertEqual(s.reason, "")
    }

    func testCodableRoundTrip() throws {
        let date = Date()
        let expires = date.addingTimeInterval(3600)
        let session = KeepAwakeSession(
            active: true,
            preventDisplaySleep: true,
            startedAt: date,
            expiresAt: expires,
            reason: "testing"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(KeepAwakeSession.self, from: data)

        XCTAssertTrue(decoded.active)
        XCTAssertTrue(decoded.preventDisplaySleep)
        XCTAssertEqual(decoded.reason, "testing")
        // Date comparison with 1-second tolerance
        XCTAssertEqual(decoded.startedAt.timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(decoded.expiresAt!.timeIntervalSince1970,
                       expires.timeIntervalSince1970, accuracy: 1.0)
    }

    func testCodableSnakeCaseKeys() throws {
        let session = KeepAwakeSession(
            active: true,
            preventDisplaySleep: true,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            reason: "test"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(session)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("prevent_display_sleep"))
        XCTAssertTrue(json.contains("started_at"))
        XCTAssertTrue(json.contains("expires_at"))
        XCTAssertFalse(json.contains("preventDisplaySleep"))
    }
}

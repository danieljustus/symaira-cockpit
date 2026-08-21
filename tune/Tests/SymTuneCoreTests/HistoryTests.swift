import XCTest
@testable import SymTuneCore

final class HistoryTests: XCTestCase {
    private var tmpDir: URL!
    private var service: HistoryService!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-history-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        service = HistoryService(dataDir: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testLogAndReadEvents() throws {
        let e1 = HistoryEvent(
            timestamp: Date(),
            action: "brightness.set",
            requestedValue: 0.85,
            clampedValue: 0.85,
            appliedValue: 0.85,
            result: "success"
        )
        let e2 = HistoryEvent(
            timestamp: Date(),
            action: "dim.set",
            requestedValue: 0.05,
            clampedValue: 0.15,
            appliedValue: 0.15,
            result: "success"
        )
        let e3 = HistoryEvent(
            timestamp: Date(),
            action: "fan.set",
            requestedValue: 1.5,
            clampedValue: 1.0,
            appliedValue: nil,
            result: "failed",
            errorReason: "helper connection failed"
        )

        service.logEvent(e1)
        service.logEvent(e2)
        service.logEvent(e3)

        // Read all events (chronological order)
        let events = service.readEvents(limit: nil)
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0].action, "brightness.set")
        XCTAssertEqual(events[1].action, "dim.set")
        XCTAssertEqual(events[2].action, "fan.set")

        // Test limit (last 2 events: dim.set, fan.set)
        let limited = service.readEvents(limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited[0].action, "dim.set")
        XCTAssertEqual(limited[1].action, "fan.set")
    }

    func testHistoryFilePermissions() throws {
        let e = HistoryEvent(timestamp: Date(), action: "test", requestedValue: 1.0, clampedValue: 1.0, appliedValue: 1.0, result: "success")
        service.logEvent(e)

        let file = tmpDir.appendingPathComponent("history.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        if let posix = attrs[.posixPermissions] as? NSNumber {
            XCTAssertEqual(posix.uint16Value & 0o777, 0o600)
        }
    }

    func testUnwritableDirectoryDoesNotThrow() throws {
        let readOnlyDir = tmpDir.appendingPathComponent("readonly-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDir.path)
        }

        let roService = HistoryService(dataDir: readOnlyDir)
        let e = HistoryEvent(timestamp: Date(), action: "test", requestedValue: 1.0, clampedValue: 1.0, appliedValue: 1.0, result: "success")

        // Should log warning to stderr but NOT throw
        XCTAssertNoThrow(roService.logEvent(e))
    }

    func testControllerHistoryIntegration() throws {
        // Create a controller with a mock/fake display write service and temp dataDir
        let mockDir = tmpDir.appendingPathComponent("controller-mock-data", isDirectory: true)
        let controller = TuneController(
            config: TuneConfig(dimMin: 0.2, dimMax: 0.8, brightnessMin: 0.2, brightnessMax: 0.8),
            displayWrite: FakeDisplayWriteService(),
            dataDir: mockDir
        )

        // Verify history starts empty
        XCTAssertTrue(controller.getHistory().isEmpty)

        // Perform normal brightness write -> clamped (since 0.9 is above 0.8 config max)
        try controller.applyBuiltinBrightness(0.9)

        var history = controller.getHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].action, "brightness.set")
        XCTAssertEqual(history[0].requestedValue, 0.9)
        XCTAssertEqual(history[0].clampedValue, 0.8)
        XCTAssertEqual(history[0].appliedValue, 0.8)
        XCTAssertEqual(history[0].result, "success")

        // Perform a failed write path (fan set without SMC access in tests)
        XCTAssertThrowsError(try controller.applyFan(fraction: 0.5))

        history = controller.getHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1].action, "fan.set")
        XCTAssertEqual(history[1].requestedValue, 0.5)
        XCTAssertEqual(history[1].clampedValue, 0.5)
        XCTAssertNil(history[1].appliedValue)
        XCTAssertEqual(history[1].result, "failed")
        XCTAssertNotNil(history[1].errorReason)
    }

    /// Issue #312: `logHistory` must route the error text through
    /// `SecretRedactor` before it's persisted, so a credential-shaped
    /// substring embedded in an underlying error never reaches
    /// history.ndjson verbatim.
    func testLogHistoryRedactsCredentialShapedError() throws {
        // Built via concatenation (not a real-format literal) so this
        // string can't be mistaken for a live credential, while still
        // matching SecretRedactor's `sk-...` pattern.
        let fakeToken = "sk-" + "abcdEFGH12345678ijkl"
        let mock = MockDisplayWriteService()
        mock.setBuiltinBrightnessError = TuneError.failed("upstream rejected token \(fakeToken)")
        let controller = TuneController(config: TuneConfig(), displayWrite: mock)

        XCTAssertThrowsError(try controller.applyBuiltinBrightness(0.8))

        let history = controller.getHistory()
        let entry = try XCTUnwrap(history.last)
        XCTAssertEqual(entry.action, "brightness.set")
        XCTAssertEqual(entry.result, "failed")
        let reason = try XCTUnwrap(entry.errorReason)
        XCTAssertFalse(reason.contains(fakeToken), "credential must not appear verbatim in history: \(reason)")
        XCTAssertTrue(reason.contains(SecretRedactor.placeholder), "redaction must be visible, not silent truncation")
    }
}

// A simple fake display write service to avoid calling actual display hardware inside unit tests
private final class FakeDisplayWriteService: DisplayWriteServiceProtocol, @unchecked Sendable {
    private var brightness: Float = 0.5

    func getBuiltinBrightness() throws -> Double {
        return Double(brightness)
    }

    func setBuiltinBrightness(_ value: Float) throws {
        brightness = value
    }

    func applyExtendedBrightness(_ value: Double, displayID: CGDirectDisplayID?) throws {
        // no-op
    }

    func applyWarmth(_ warmth: Float) throws {
        // no-op
    }

    func resetWarmth() throws {
        // no-op
    }
}

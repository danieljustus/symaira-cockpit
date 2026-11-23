import XCTest
@testable import SymCockpitCore

final class FanProfileTests: XCTestCase {

    // MARK: - The three positions

    func testControlHasThreePositionsWithSystemFirst() {
        XCTAssertEqual(FanProfile.ordered, [.system, .comfort, .performance])
        XCTAssertEqual(FanProfile.system.step, 0)
        XCTAssertEqual(FanProfile.comfort.step, 1)
        XCTAssertEqual(FanProfile.performance.step, 2)
    }

    func testStepLookupClampsOutOfRangeToSystem() {
        XCTAssertEqual(FanProfile.at(step: 1), .comfort)
        XCTAssertEqual(FanProfile.at(step: -1), .system)
        XCTAssertEqual(FanProfile.at(step: 3), .system)
    }

    // MARK: - Curve shape

    // MARK: - Governing temperature

    private func report(_ readings: [(String, Double)]) -> SensorReport {
        SensorReport(
            thermalPressure: "nominal",
            smcSupported: true,
            temperatures: readings.map {
                SensorReading(key: $0.0, label: $0.0, celsius: $0.1)
            },
            fans: [],
            notes: []
        )
    }

    // MARK: - Persisted selection

    private func makeStore() throws -> FanProfileStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return FanProfileStore(url: dir.appendingPathComponent("fan-profile.json"))
    }

    func testStoreRoundTrips() throws {
        let store = try makeStore()
        try store.write(.performance)
        XCTAssertEqual(store.read(), .performance)
        try store.write(.system)
        XCTAssertEqual(store.read(), .system)
    }

    /// Every unreadable state must resolve to "don't override". A governor
    /// that read a corrupt file as an aggressive profile would hold the fans
    /// somewhere nobody asked for.
    func testStoreDefaultsToSystemWhenMissingOrCorrupt() throws {
        let store = try makeStore()
        XCTAssertEqual(store.read(), .system)

        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.read(), .system)

        try Data(#"{"profile":"turbo"}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.read(), .system)
    }

    func testStoreFileIsOwnerOnly() throws {
        let store = try makeStore()
        try store.write(.comfort)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    func testDefaultURLIsPerUser() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(
            FanProfileStore.defaultURL(home: home).path,
            "/Users/example/.symtune/fan-profile.json"
        )
    }

    /// The governor is started with `sudo`, where `homeDirectoryForCurrentUser`
    /// is `/var/root`. Reading the profile from there finds no file, resolves
    /// to `.system`, and the loop exits without ever touching a fan — the
    /// selection has to come from the account that did the elevating.
    func testInvokingUserHomeSeesThroughSudo() {
        let home = FanProfileStore.invokingUserHomeForTesting(
            environment: ["SUDO_USER": "root"],
            isRoot: true
        )
        // `root` is the one account guaranteed to exist on any macOS host, so
        // the lookup is assertable without depending on the test machine's users.
        XCTAssertEqual(home.path, "/var/root")
    }

    func testInvokingUserHomeIgnoresSudoUserWhenNotRoot() {
        // A plain user run must never adopt someone else's home just because
        // SUDO_USER is still lying around in the environment.
        let home = FanProfileStore.invokingUserHomeForTesting(
            environment: ["SUDO_USER": "root"],
            isRoot: false
        )
        XCTAssertEqual(home, FileManager.default.homeDirectoryForCurrentUser)
    }

    func testInvokingUserHomeFallsBackWithoutSudoUser() {
        let home = FanProfileStore.invokingUserHomeForTesting(environment: [:], isRoot: true)
        XCTAssertEqual(home, FileManager.default.homeDirectoryForCurrentUser)
    }
}

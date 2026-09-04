import XCTest
@testable import SymTuneCore

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

    /// The default position writes nothing at all — that is what makes it the
    /// Mac's own behavior rather than a reproduction of it.
    func testSystemProfileHasNoCurve() {
        XCTAssertNil(FanProfile.system.curve)
        XCTAssertNotNil(FanProfile.comfort.curve)
        XCTAssertNotNil(FanProfile.performance.curve)
    }

    // MARK: - Curve shape

    /// Both governed positions must start earlier and climb faster than the
    /// one to their left, at every temperature — that is the whole promise of
    /// moving the control right.
    func testEachStepRightIsAtLeastAsAggressiveAtEveryTemperature() throws {
        let comfort = try XCTUnwrap(FanProfile.comfort.curve)
        let performance = try XCTUnwrap(FanProfile.performance.curve)

        for celsius in stride(from: 30.0, through: 100.0, by: 1.0) {
            XCTAssertGreaterThanOrEqual(
                performance.fraction(at: celsius),
                comfort.fraction(at: celsius),
                "performance must not be quieter than comfort at \(celsius)°C"
            )
        }
    }

    func testPerformanceStartsRampingEarlierThanComfort() throws {
        let comfort = try XCTUnwrap(FanProfile.comfort.curve)
        let performance = try XCTUnwrap(FanProfile.performance.curve)
        // At 50 °C — a warm-idle M4 — comfort is barely off its floor while
        // performance is already well into its ramp.
        XCTAssertGreaterThan(performance.fraction(at: 50), comfort.fraction(at: 50))
    }

    /// Neither position is a fixed speed: an idle Mac stays near the floor
    /// even on "Max", and only a genuinely hot die reaches full speed. This is
    /// the explicit requirement that the aggressive settings stay
    /// temperature-dependent rather than pinning the fans at 100%.
    func testGovernedProfilesStayTemperatureDependent() throws {
        for profile in [FanProfile.comfort, .performance] {
            let curve = try XCTUnwrap(profile.curve)
            XCTAssertLessThan(
                curve.fraction(at: 35),
                0.6,
                "\(profile.rawValue) must stay quiet on an idle Mac"
            )
            XCTAssertEqual(
                curve.fraction(at: 95),
                1.0,
                accuracy: 0.001,
                "\(profile.rawValue) must reach full speed on a hot die"
            )
            // Monotonic: hotter never means slower.
            var previous = 0.0
            for celsius in stride(from: 20.0, through: 110.0, by: 1.0) {
                let value = curve.fraction(at: celsius)
                XCTAssertGreaterThanOrEqual(value, previous)
                previous = value
            }
        }
    }

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

    /// The curve follows the CPU/GPU die, not whatever sensor happens to be
    /// hottest. An enclosure or battery sensor lags the die by tens of degrees
    /// and would make the governor spin up long after the chip needed it.
    func testGoverningTemperatureUsesDieSensors() {
        let value = FanProfile.governingTemperature(in: report([
            ("TCMz", 88.0),   // CPU die hotspot
            ("TRDX", 61.0),   // GPU die hotspot
            ("TW0P", 51.0),   // Wi-Fi module — not a die sensor
        ]))
        XCTAssertEqual(value ?? 0, 88.0, accuracy: 0.001)
    }

    func testGoverningTemperatureTakesHottestOfCPUAndGPU() {
        let value = FanProfile.governingTemperature(in: report([
            ("TCMz", 55.0),
            ("TRDX", 92.0),   // GPU is the hot one this time
        ]))
        XCTAssertEqual(value ?? 0, 92.0, accuracy: 0.001)
    }

    /// An unfamiliar Mac still gets governed — from a coarser sensor rather
    /// than not at all.
    func testGoverningTemperatureFallsBackToHottestReading() {
        let value = FanProfile.governingTemperature(in: report([("ZZZZ", 71.0)]))
        XCTAssertEqual(value ?? 0, 71.0, accuracy: 0.001)
    }

    func testGoverningTemperatureIsNilWithoutReadings() {
        XCTAssertNil(FanProfile.governingTemperature(in: report([])))
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

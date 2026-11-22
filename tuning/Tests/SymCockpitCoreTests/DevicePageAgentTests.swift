import XCTest
@testable import SymCockpitCore

@MainActor
final class DevicePageAgentTests: XCTestCase {
    private var directory: URL!
    private var requestLog: URL { directory.appendingPathComponent("requests.ndjson") }
    private var sessions: [AgentSession] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-device-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.stop() }
        try FileManager.default.removeItem(at: directory)
    }

    private func start(bluetoothAuthorization: String? = nil) async throws -> AgentSession {
        let fixtures = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        var fixture = fixtures.appendingPathComponent("device-page-agent.json")
        if let bluetoothAuthorization {
            let data = try Data(contentsOf: fixture)
            var contents = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var ble = try XCTUnwrap(contents["ble.session"] as? [String: Any])
            ble["authorization"] = bluetoothAuthorization
            contents["ble.session"] = ble
            fixture = directory.appendingPathComponent("permission-fixture.json")
            try JSONSerialization.data(withJSONObject: contents).write(to: fixture)
        }
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [fixtures.appendingPathComponent("fake-agent.pl").path, "ok"],
            environment: ["FAKE_AGENT_FIXTURES": fixture.path, "FAKE_AGENT_LOG": requestLog.path],
            requestTimeout: 5
        ))
        sessions.append(session)
        await session.start()
        XCTAssertNotNil(session.hello)
        return session
    }

    private func requests(_ method: String, command: String? = nil) throws -> [AgentJSON] {
        let text = try String(contentsOf: requestLog, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(AgentJSON.self, from: Data($0.utf8))
        }.filter {
            $0["method"]?.stringValue == method && (command == nil || $0["params"]?["command"]?.stringValue == command)
        }
    }

    private func arguments(_ command: String) throws -> AgentJSON {
        let request = try XCTUnwrap(requests("call", command: command).last)
        return try XCTUnwrap(request["params"]?["params"])
    }

    func testAudioAndMIDIReadPassivelyAndUnsubscribeWhenHidden() async throws {
        let session = try await start()
        let model = AudioMIDIModel(session: session)
        model.setVisible(true)
        await session.settled()
        await model.refresh()

        XCTAssertEqual(model.devices.value?.defaultOutputUid, "speakers")
        XCTAssertEqual(model.devices.value?.devices(for: .input).map(\.uid), ["headset"])
        XCTAssertEqual(model.midi.value?.devices.first?.inputs, 1)
        XCTAssertEqual(model.midi.value?.standaloneDestinations.first?.name, "Virtual destination")
        XCTAssertEqual(model.mixerApps.first?.target, "example.player")
        XCTAssertEqual(model.captureAccess, .unknown)
        XCTAssertEqual(try requests("subscribe").count, 3)
        XCTAssertTrue(try requests("call", command: "audio.app-volume.set").isEmpty)
        XCTAssertTrue(try requests("call", command: "audio.mixer.run").isEmpty)

        model.setVisible(false)
        await session.settled()
        XCTAssertEqual(try requests("unsubscribe").count, 3)
        XCTAssertEqual(model.devices, .idle)
    }

    func testDeviceControlsAndFormatAndAggregateUseContractArguments() async throws {
        let session = try await start()
        let model = AudioMIDIModel(session: session)
        model.setVisible(true)
        await model.refresh()
        let list = try XCTUnwrap(model.devices.value)
        let speakers = try XCTUnwrap(list.devices.first { $0.uid == "speakers" })
        let headset = try XCTUnwrap(list.devices.first { $0.uid == "headset" })

        await model.setDefault(.output, device: headset)
        await model.setVolume(0.25, device: speakers, direction: .output)
        await model.setMuted(true, device: speakers, direction: .output)
        XCTAssertEqual(try arguments("audio.default.set"), .object(["uid": .string("headset"), "direction": .string("output")]))
        XCTAssertEqual(try arguments("audio.volume.set")["value"], .number(0.25))
        XCTAssertEqual(try arguments("audio.mute.set")["muted"], .bool(true))

        let options = await model.loadFormats(for: speakers)
        XCTAssertEqual(options.value?.output.formats.map(\.bits), [16, 24])
        await model.requestFormat(44_100, bits: 16, device: speakers)
        XCTAssertEqual(model.pending?.confirmation.plan.command, "audio.format.set")
        XCTAssertEqual(try arguments("audio.format.set")["bits"], .number(16))
        XCTAssertTrue(try requests("confirm").isEmpty)
        XCTAssertTrue(try requests("call", command: "plan.confirm").isEmpty)

        model.dismissPending()
        await model.requestAggregate(name: " Combined ", members: ["headset", "speakers"], main: "speakers", multiOutput: true)
        XCTAssertEqual(model.pending?.confirmation.plan.command, "audio.aggregate.create")
        XCTAssertEqual(try arguments("audio.aggregate.create"), .object([
            "name": .string("Combined"), "members": .array([.string("headset"), .string("speakers")]),
            "main": .string("speakers"), "multi_output": .bool(true),
        ]))
        XCTAssertTrue(try requests("confirm").isEmpty)
        XCTAssertTrue(try requests("call", command: "plan.confirm").isEmpty)
    }

    func testMixerFailureDoesNotClaimRecordingPermission() async throws {
        let session = try await start()
        let model = AudioMIDIModel(session: session)
        model.setVisible(true)
        await model.refresh()
        let app = try XCTUnwrap(model.mixerApps.first)
        await model.setAppVolume(0.35, muted: false, app: app)

        XCTAssertEqual(try arguments("audio.app-volume.set"), .object([
            "app": .string("example.player"), "volume": .number(0.35), "muted": .bool(false),
        ]))
        XCTAssertEqual(model.failure, "Process tap did not start.")
        XCTAssertEqual(model.captureAccess, .unknown)
    }

    func testBLEUsesPassiveAuthorizationThenExplicitScanReadPlanAndExport() async throws {
        let session = try await start()
        let model = BluetoothModel(session: session)
        model.setVisible(true)
        await session.settled()
        await model.loadPaired()
        await model.refreshSession()

        let buds = try XCTUnwrap(model.paired.value?.first)
        XCTAssertTrue(buds.connected)
        XCTAssertEqual(buds.battery.summary, "L 60 % · R 55 % · Case 40 %")
        XCTAssertEqual(model.access, .notDetermined)
        XCTAssertEqual(try requests("subscribe", command: "ble.session").count, 1)
        for command in ["ble.scan", "ble.connect", "ble.services", "ble.read", "ble.export", "ble.write"] {
            XCTAssertTrue(try requests("call", command: command).isEmpty, command)
        }

        await model.startScan(seconds: 5, filter: " Sensor ")
        guard case .finished(let scan) = model.scan else { return XCTFail("Expected scan result") }
        XCTAssertEqual(scan.devices.first?.serviceUuids, ["180F"])
        XCTAssertEqual(try arguments("ble.scan"), .object(["timeout_seconds": .number(5), "filter": .string("Sensor")]))
        await model.loadServices("id-a")
        guard case .loaded(let tree) = model.gatt else { return XCTFail("Expected GATT discovery") }
        let characteristic = try XCTUnwrap(tree.services.first?.characteristics.first)
        await model.read(device: "id-a", service: "180F", characteristic: characteristic.uuid)
        XCTAssertEqual(model.readings["id-a|180f|2a19"]?.valueHex, "01")

        await model.requestWrite(device: "id-a", service: "180F", characteristic: characteristic, hex: "0xDE:ad")
        let plan = try XCTUnwrap(model.pending?.confirmation)
        XCTAssertEqual(try arguments("ble.write")["value_hex"], .string("dead"))
        XCTAssertEqual(try arguments("ble.write")["with_response"], .bool(true))
        XCTAssertTrue(try requests("confirm").isEmpty)
        XCTAssertTrue(try requests("call", command: "plan.confirm").isEmpty)
        let report = await plan.confirm()
        XCTAssertEqual(report?.isConfirmed, true)
        XCTAssertTrue(try requests("confirm").isEmpty)
        XCTAssertEqual(try arguments("plan.confirm")["plan_id"], .string(plan.plan.id))

        await model.loadLog()
        let csv = await model.export(.csv)
        XCTAssertEqual(csv?.data, Data("fixture,csv\r\n".utf8))
        XCTAssertEqual(try arguments("ble.export")["format"], .string("csv"))
        model.setVisible(false)
        await session.settled()
        XCTAssertEqual(try requests("unsubscribe").count, 1)
    }

    func testDeniedBluetoothScanAndFinderPermissionArePassive() async throws {
        let session = try await start(bluetoothAuthorization: "denied")
        let bluetooth = BluetoothModel(session: session)
        bluetooth.setVisible(true)
        await bluetooth.refreshSession()
        XCTAssertEqual(bluetooth.access, .denied)
        XCTAssertFalse(bluetooth.canScan)
        await bluetooth.startScan(seconds: 5, filter: "")
        XCTAssertTrue(try requests("call", command: "ble.scan").isEmpty)

        let input = InputModel(session: session)
        input.setVisible(true)
        await input.refresh()
        XCTAssertEqual(input.status.value?.finderCut.hasAccess, true)
        XCTAssertTrue(try requests("call", command: "input.finder-cut").isEmpty)
        XCTAssertTrue(try requests("call", command: "input.haptics.test").isEmpty)
        await input.setFinderCut(true)
        XCTAssertEqual(try arguments("input.finder-cut")["state"], .string("on"))
        XCTAssertEqual(input.status.value?.finderCut.enabled, true)
        await input.testHaptics()
        XCTAssertEqual(input.testResult?.haptic.status, "no_device")
        XCTAssertEqual(input.testResult?.sound.status, "ok")
    }
}

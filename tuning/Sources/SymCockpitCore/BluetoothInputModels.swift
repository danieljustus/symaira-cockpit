import Foundation
import Observation

// The models of the Bluetooth & Input page. Bluetooth: `bt.devices` (paired devices, read
// when the page opens), the BLE session of the agent (`ble.scan`, `ble.connect`,
// `ble.services`, `ble.read`, `ble.log`, `ble.export`, `ble.session`) and the risky
// `ble.write`, which only ever comes back as a plan. Input: `input.status`,
// `input.finder-cut`, `input.haptics.test`. Neither owns a radio or an event tap. The
// BLE authorization comes from the passive session snapshot. A scan is only ever
// started by the person.

// MARK: - Shapes

public struct BluetoothLevel: Decodable, Equatable, Sendable {
    /// `known` or `unknown`: a missing reading is never 0 %.
    public let state: String
    public let percent: Int?

    public var text: String? { state == "known" ? percent.map { "\($0) %" } : nil }
}

public struct BluetoothBattery: Decodable, Equatable, Sendable {
    public let main: BluetoothLevel
    public let left: BluetoothLevel?
    public let right: BluetoothLevel?
    public let caseLevel: BluetoothLevel?

    private enum CodingKeys: String, CodingKey {
        case main, left, right, caseLevel = "case"
    }

    /// One line for the row: the main level, or the parts of earbuds, or nothing known.
    public var summary: String {
        let parts = [("L", left), ("R", right), ("Case", caseLevel)].compactMap { label, level in
            level?.text.map { "\(label) \($0)" }
        }
        if let main = main.text { return parts.isEmpty ? main : ([main] + parts).joined(separator: " · ") }
        return parts.isEmpty ? "Battery unknown" : parts.joined(separator: " · ")
    }
}

public struct PairedDevice: Decodable, Equatable, Sendable {
    public let name: String
    /// Lower-case device class (`headphones`, `keyboard`, …), `unknown` when not reported.
    public let kind: String
    public let connected: Bool
    public let battery: BluetoothBattery
}

public struct BleAdvertisement: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let rssi: Int?
    public let serviceUuids: [String]
    public let connectable: Bool?
}

public struct BleScanResult: Decodable, Equatable, Sendable {
    public let timeoutMs: Int
    public let totalSeen: Int
    public let shown: Int
    public let devices: [BleAdvertisement]
}

public struct BleCharacteristic: Decodable, Equatable, Sendable, Identifiable {
    public let uuid: String
    /// `read`, `write`, `write_without_response`, `notify`, …
    public let properties: [String]

    public var id: String { uuid }
    public var canRead: Bool { properties.contains("read") }
    public var canWrite: Bool { properties.contains("write") || properties.contains("write_without_response") }
    /// Writing without a response is the only way when the characteristic offers nothing else.
    public var writesWithResponse: Bool { properties.contains("write") }
}

public struct BleService: Decodable, Equatable, Sendable, Identifiable {
    public let uuid: String
    public let characteristics: [BleCharacteristic]

    public var id: String { uuid }
}

public struct BleServices: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let services: [BleService]
}

public struct BleReading: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let service: String
    public let characteristic: String
    public let length: Int
    public let valueHex: String

    public static func key(device: String, service: String, characteristic: String) -> String {
        [device, service.lowercased(), characteristic.lowercased()].joined(separator: "|")
    }
}

public struct BleSessionInfo: Decodable, Equatable, Sendable {
    public struct Subscription: Decodable, Equatable, Sendable {
        public let deviceId: String
        public let service: String
        public let characteristic: String
    }

    public let connections: [String]
    public let subscriptions: [Subscription]
    public let logEntries: Int
    public let logSeq: Int
    public let authorization: String?
}

public struct BleLogEntry: Decodable, Equatable, Sendable, Identifiable {
    public let seq: Int
    public let tMs: Int
    public let kind: String
    public let deviceId: String
    public let service: String
    public let characteristic: String
    public let valueHex: String
    public let detail: String

    public var id: Int { seq }
    public var date: Date { Date(timeIntervalSince1970: Double(tMs) / 1000) }
}

public struct BleLog: Decodable, Equatable, Sendable {
    public let count: Int
    public let entries: [BleLogEntry]
}

/// What the person may save: the agent's raw BLE log as CSV or JSON.
public struct BleExport: Equatable, Sendable {
    public let suggestedName: String
    public let data: Data
}

public enum BleExportFormat: String, Sendable, CaseIterable {
    case csv, json
}

public enum BluetoothAccess: Equatable, Sendable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted

    public var blocksRadioActions: Bool { self == .denied || self == .restricted }
}

public enum BleScanState: Equatable, Sendable {
    case idle
    case scanning(seconds: Int)
    case finished(BleScanResult)
    case failed(String)
}

public enum GattState: Equatable, Sendable {
    case idle
    case loading(deviceID: String)
    case loaded(BleServices)
    case failed(String)
}

// MARK: - Bluetooth

@MainActor
@Observable
public final class BluetoothModel {
    public private(set) var paired: LoadState<[PairedDevice]> = .idle
    public private(set) var access: BluetoothAccess = .unknown
    public private(set) var scan: BleScanState = .idle
    public private(set) var bleSession: LoadState<BleSessionInfo> = .idle
    public private(set) var gatt: GattState = .idle
    public private(set) var readings: [String: BleReading] = [:]
    /// The key of the characteristic being read, or the device being connected.
    public private(set) var busy: String?
    public private(set) var log: LoadState<BleLog> = .idle
    public private(set) var pending: DevicePlan?
    public private(set) var failure: String?
    public private(set) var isPlanning = false
    public private(set) var isExporting = false
    public private(set) var isLoadingPaired = false

    @ObservationIgnored private let agent: AgentSession
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var generation = 0
    private static let owner = "bluetooth"

    public init(session: AgentSession) {
        self.agent = session
    }

    public var isScanning: Bool {
        if case .scanning = scan { return true }
        return false
    }

    public func isConnected(_ deviceID: String) -> Bool {
        bleSession.value?.connections.contains(deviceID) == true
    }

    public var radioIsBusy: Bool {
        if case .loading = gatt { return true }
        return isScanning || busy != nil || isPlanning || pending?.isOpen == true
    }

    public func offers(_ command: String) -> Bool {
        agent.hello?.commands.contains { $0.name == command } == true
    }

    public var canScan: Bool {
        offers("ble.scan") && bleSession.value != nil && !access.blocksRadioActions && !radioIsBusy
    }

    // MARK: Lifecycle

    /// The BLE session is a memory-only topic: sampled only while the page is on screen.
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        generation += 1
        let generation = generation
        if visible {
            bleSession = .loading
            token = agent.subscribe("ble.session", visibleMs: 2000) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.receive(event)
                }
            }
        } else {
            if let token { agent.unsubscribe(token) }
            token = nil
            paired = .idle
            bleSession = .idle
            access = .unknown
            log = .idle
            pending = nil
        }
        agent.setVisible(visible, owner: Self.owner)
    }

    func receive(_ event: AgentEvent) {
        guard isVisible, event.command == "ble.session" else { return }
        switch event.payload {
        case .result(let json): applySession(json)
        case .error(let error): bleSession = .failed(SecretRedactor.redact(error.message))
        }
    }

    private func applySession(_ json: AgentJSON) {
        guard let info = try? AgentDecoding.decode(BleSessionInfo.self, from: json) else {
            bleSession = .failed("The BLE session could not be read.")
            return
        }
        let grew = info.logSeq != bleSession.value?.logSeq
        bleSession = .loaded(info)
        switch info.authorization {
        case "not_determined": access = .notDetermined
        case "allowed": access = .granted
        case "denied": access = .denied
        case "restricted": access = .restricted
        default: break
        }
        if grew { Task { await loadLog() } }
    }

    // MARK: Paired devices

    public func loadPaired() async {
        guard isVisible, !isLoadingPaired else { return }
        isLoadingPaired = true
        defer { isLoadingPaired = false }
        if paired.value == nil { paired = .loading }
        let generation = generation
        let result = await agent.perform("bt.devices")
        guard self.generation == generation else { return }
        switch result {
        case .done(let output):
            do {
                paired = .loaded(try AgentDecoding.decode([PairedDevice].self, from: output["devices"] ?? .null))
            } catch {
                paired = .failed("The paired devices could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, _): paired = .failed(SecretRedactor.redact(message))
        case .needsConfirmation: paired = .failed("The Cockpit agent asked for a confirmation to read this.")
        }
    }

    // MARK: Scan

    /// Scans for `seconds` (1 to 30). Only ever started by the person; the first scan is
    /// what makes macOS ask for Bluetooth access, if it has not been asked.
    public func startScan(seconds: Int, filter: String) async {
        guard isVisible, canScan, (1...30).contains(seconds) else { return }
        failure = nil
        scan = .scanning(seconds: seconds)
        var params: [String: AgentJSON] = ["timeout_seconds": .number(Double(seconds))]
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { params["filter"] = .string(trimmed) }
        switch await agent.perform("ble.scan", params: params) {
        case .done(let output):
            do {
                scan = .finished(try AgentDecoding.decode(BleScanResult.self, from: output))
                access = .granted
            } catch {
                scan = .failed("The scan result could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            scan = .failed(text)
            note(exitClass)
        case .needsConfirmation:
            scan = .failed("The Cockpit agent asked for a confirmation; nothing was scanned.")
        }
        await refreshSession()
    }

    private func note(_ exitClass: String?) {
        if exitClass == "permission", access != .restricted { access = .denied }
    }

    // MARK: Connection and GATT

    public func disconnect(_ id: String) async {
        guard isVisible, !radioIsBusy else { return }
        busy = id
        defer { busy = nil }
        if await run("ble.disconnect", ["device_id": .string(id)]) {
            if case .loaded(let services) = gatt, services.deviceId == id { gatt = .idle }
        }
        await refreshSession()
    }

    /// The services and characteristics of a device. The agent connects when needed.
    public func loadServices(_ id: String) async {
        guard isVisible, !radioIsBusy, !access.blocksRadioActions else { return }
        gatt = .loading(deviceID: id)
        failure = nil
        switch await agent.perform("ble.services", params: ["device_id": .string(id)]) {
        case .done(let output):
            do {
                gatt = .loaded(try AgentDecoding.decode(BleServices.self, from: output))
                access = .granted
            } catch {
                gatt = .failed("The services could not be read: \(error.localizedDescription)")
            }
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            gatt = .failed(text)
            note(exitClass)
        case .needsConfirmation:
            gatt = .failed("The Cockpit agent asked for a confirmation; nothing was read.")
        }
        await refreshSession()
    }

    public func read(device: String, service: String, characteristic: String) async {
        guard isVisible, !radioIsBusy, !access.blocksRadioActions else { return }
        let key = BleReading.key(device: device, service: service, characteristic: characteristic)
        busy = key
        readings[key] = nil
        failure = nil
        defer { busy = nil }
        let params: [String: AgentJSON] = [
            "device_id": .string(device), "service": .string(service), "characteristic": .string(characteristic),
        ]
        switch await agent.perform("ble.read", params: params) {
        case .done(let output):
            do {
                readings[key] = try AgentDecoding.decode(BleReading.self, from: output)
            } catch {
                failure = "The value could not be read: \(error.localizedDescription)"
            }
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            failure = text
            note(exitClass)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was read."
        }
        await refreshSession()
    }

    @discardableResult
    private func run(_ command: String, _ params: [String: AgentJSON]) async -> Bool {
        failure = nil
        switch await agent.perform(command, params: params) {
        case .done:
            return true
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            failure = text
            note(exitClass)
        case .needsConfirmation:
            failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        return false
    }

    public func refreshSession() async {
        guard isVisible else { return }
        let generation = generation
        let result = await agent.perform("ble.session")
        guard self.generation == generation else { return }
        switch result {
        case .done(let output): applySession(output)
        case .failed(let message, _): bleSession = .failed(SecretRedactor.redact(message))
        case .needsConfirmation: bleSession = .failed("The agent asked for confirmation to read the BLE session.")
        }
    }

    // MARK: Write (a plan)

    /// Bytes as hex without separators, or `nil` when the text is not 1 to 512 bytes of hex.
    public static func normalizedHex(_ text: String) -> String? {
        var hex = text.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count % 2 == 0, hex.count <= 1024,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return hex
    }

    /// Records the write. Nothing is sent until the person confirms the plan.
    public func requestWrite(device: String, service: String, characteristic: BleCharacteristic, hex: String) async {
        guard isVisible, !radioIsBusy, !access.blocksRadioActions, characteristic.canWrite else { return }
        guard let bytes = Self.normalizedHex(hex) else {
            failure = "Enter 1 to 512 bytes as hex, for example 01 ff 0a."
            return
        }
        failure = nil
        pending = nil
        isPlanning = true
        defer { isPlanning = false }
        let withResponse = characteristic.writesWithResponse
        let params: [String: AgentJSON] = [
            "device_id": .string(device), "service": .string(service),
            "characteristic": .string(characteristic.uuid), "value_hex": .string(bytes),
            "with_response": .bool(withResponse),
        ]
        switch await agent.perform("ble.write", params: params) {
        case .needsConfirmation(let plan):
            guard isVisible else { return }
            let confirmation = PlanConfirmationModel(plan: plan, session: agent)
            confirmation.onFinished = { [weak self, weak confirmation] _ in
                guard let self, let confirmation, self.pending?.confirmation === confirmation else { return }
                Task { await self.refreshSession() }
            }
            pending = DevicePlan(
                confirmation: confirmation,
                summary: "Write \(bytes.count / 2) byte\(bytes.count == 2 ? "" : "s") (\(bytes)) to characteristic \(characteristic.uuid) of \(device).",
                confirmTitle: "Write to Device"
            )
        case .done:
            failure = "The agent returned an unexpected result for the write plan. Check the BLE log."
        case .failed(let message, let exitClass):
            let text = SecretRedactor.redact(message)
            failure = text
            note(exitClass)
        }
    }

    public func dismissPending() {
        pending = nil
    }

    // MARK: Log and export

    public func loadLog() async {
        guard isVisible, offers("ble.log"), log != .loading else { return }
        log = .loading
        let generation = generation
        let result = await agent.perform("ble.log")
        guard self.generation == generation else { return }
        switch result {
        case .done(let output):
            do {
                log = .loaded(try AgentDecoding.decode(BleLog.self, from: output))
            } catch {
                log = .failed("The BLE log could not be read.")
            }
        case .failed(let message, _): log = .failed(SecretRedactor.redact(message))
        case .needsConfirmation: log = .failed("The agent asked for confirmation to read the BLE log.")
        }
    }

    /// The raw log, only when the person asks for it (it holds the bytes that were read and written).
    public func export(_ format: BleExportFormat) async -> BleExport? {
        guard isVisible, offers("ble.export"), !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        failure = nil
        let result = await agent.perform("ble.export", params: ["format": .string(format.rawValue)])
        guard isVisible else { return nil }
        guard case .done(let output) = result else {
            failure = result.failureMessage.map(SecretRedactor.redact) ?? "The BLE log could not be exported."
            return nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "ble-log-\(stamp).\(format.rawValue)"
        switch format {
        case .csv:
            guard let content = output["content"]?.stringValue else {
                failure = "The agent sent no CSV content."
                return nil
            }
            return BleExport(suggestedName: name, data: Data(content.utf8))
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(output) else {
                failure = "The BLE log could not be encoded."
                return nil
            }
            return BleExport(suggestedName: name, data: data)
        }
    }
}

// MARK: - Input

public struct InputFinderCut: Decodable, Equatable, Sendable {
    public let enabled: Bool
    /// `granted` or `denied`: the Accessibility permission the Finder shortcut needs.
    public let eventTapAccess: String
    public let secureInputActive: Bool

    public var hasAccess: Bool { eventTapAccess == "granted" }
}

public struct InputHapticState: Decodable, Equatable, Sendable {
    public let level: String
    public let detail: String?
}

public struct InputHaptics: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let state: InputHapticState

    public var isAvailable: Bool { state.level == "available" }
}

public struct InputStatus: Decodable, Equatable, Sendable {
    public let finderCut: InputFinderCut
    public let haptics: InputHaptics
}

public struct InputChannel: Decodable, Equatable, Sendable {
    /// `ok`, `skipped_disabled`, a haptic level name, or `failed`.
    public let status: String
    public let detail: String?
}

public struct HapticTestReport: Decodable, Equatable, Sendable {
    public let haptic: InputChannel
    public let sound: InputChannel
    public let degraded: Bool
}

extension InputHapticState {
    /// What the haptic level means for the person.
    public var explanation: String {
        switch level {
        case "available": "The trackpad can give feedback."
        case "no_device": "No trackpad with haptic feedback is connected to this Mac."
        case "framework_missing", "symbol_missing": "This version of macOS does not offer haptic feedback to Cockpit."
        case "actuator_open_failed": "The trackpad did not open for haptic feedback."
        case "actuation_failed": "The trackpad did not respond to the last haptic request."
        default: "Haptic feedback reports “\(level)”."
        }
    }
}

@MainActor
@Observable
public final class InputModel {
    public private(set) var status: LoadState<InputStatus> = .idle
    public private(set) var failure: String?
    public private(set) var testResult: HapticTestReport?
    public private(set) var isTesting = false
    public private(set) var isSwitching = false

    @ObservationIgnored private let session: AgentSession
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var generation = 0
    private static let owner = "input"

    public init(session: AgentSession) {
        self.session = session
    }

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        generation += 1
        let generation = generation
        if visible {
            status = .loading
            token = session.subscribe("input.status", visibleMs: 2000) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.receive(event)
                }
            }
        } else {
            if let token { session.unsubscribe(token) }
            token = nil
            status = .idle
            testResult = nil
        }
        session.setVisible(visible, owner: Self.owner)
    }

    func receive(_ event: AgentEvent) {
        guard isVisible, event.command == "input.status" else { return }
        switch event.payload {
        case .result(let json): apply(json)
        case .error(let error): status = .failed(SecretRedactor.redact(error.message))
        }
    }

    private func apply(_ json: AgentJSON) {
        do {
            status = .loaded(try AgentDecoding.decode(InputStatus.self, from: json))
        } catch {
            status = .failed("The input settings could not be read: \(error.localizedDescription)")
        }
    }

    public func refresh() async {
        guard isVisible else { return }
        if status.value == nil { status = .loading }
        let generation = generation
        let result = await session.perform("input.status")
        guard self.generation == generation else { return }
        switch result {
        case .done(let output): apply(output)
        case .failed(let message, _): status = .failed(SecretRedactor.redact(message))
        case .needsConfirmation: status = .failed("The Cockpit agent asked for a confirmation to read this.")
        }
    }

    /// Finder ⌘X on or off. The agent stores the choice and runs the event tap itself, and
    /// only when Accessibility access is granted.
    public func setFinderCut(_ enabled: Bool) async {
        guard isVisible, !isSwitching, let finder = status.value?.finderCut,
              finder.enabled != enabled, !enabled || finder.hasAccess else { return }
        isSwitching = true
        failure = nil
        defer { isSwitching = false }
        switch await session.perform("input.finder-cut", params: ["state": .string(enabled ? "on" : "off")]) {
        case .done: break
        case .failed(let message, _): failure = SecretRedactor.redact(message)
        case .needsConfirmation: failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
        await refresh()
    }

    /// One click with sound, whatever the switches say. Changes no setting.
    public func testHaptics() async {
        guard isVisible, !isTesting else { return }
        isTesting = true
        failure = nil
        testResult = nil
        defer { isTesting = false }
        switch await session.perform("input.haptics.test") {
        case .done(let output):
            do {
                testResult = try AgentDecoding.decode(HapticTestReport.self, from: output)
            } catch {
                failure = "The test result could not be read: \(error.localizedDescription)"
            }
        case .failed(let message, _): failure = SecretRedactor.redact(message)
        case .needsConfirmation: failure = "The Cockpit agent asked for a confirmation; nothing was changed."
        }
    }
}

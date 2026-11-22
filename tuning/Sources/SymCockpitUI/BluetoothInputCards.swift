import SwiftUI
import SymCockpitCore
import SymairaTheme
import UniformTypeIdentifiers

@MainActor
struct BLEExplorerCard: View {
    let model: BluetoothModel
    @State private var filter = ""
    @State private var duration = 5

    var body: some View {
        SymairaFormSection("Bluetooth Low Energy") {
            if model.offers("ble.scan") {
                authorization
                SymairaFormDivider()
                scanControls
                scanResults
                gattDetails
            } else {
                SymairaFormRow("Scanning Unavailable", description: "This agent does not offer Bluetooth LE scans.")
            }
        }
    }

    @ViewBuilder
    private var authorization: some View {
        switch model.bleSession {
        case .idle, .loading:
            SymairaLoadingState("Checking Bluetooth access…")
        case .failed(let message):
            SymairaFormRow("Bluetooth Access Unavailable", description: message) {
                Button("Retry") { Task { await model.refreshSession() } }.symairaButtonStyle(.secondary)
            }
        case .loaded:
            switch model.access {
            case .granted:
                SymairaFormRow("Bluetooth Access") { SymairaStatusLabel("Granted", tone: .positive) }
            case .notDetermined:
                SymairaFormRow("Bluetooth Access", description: "macOS may ask for permission when you start a scan.")
            case .denied:
                SymairaFormRow("Bluetooth Access Denied", description: "Allow Cockpit in Privacy & Security to scan.") {
                    DeviceSettingsLink("Open Bluetooth Privacy", pane: "com.apple.preference.security?Privacy_Bluetooth")
                }
            case .restricted:
                SymairaFormRow("Bluetooth Access Restricted", description: "macOS restricts Bluetooth access for Cockpit.")
            case .unknown:
                SymairaFormRow(
                    "Bluetooth Access",
                    description: "Permission status is unavailable. macOS may ask when you start a scan."
                )
            }
        }
    }

    private var scanControls: some View {
        VStack(spacing: 0) {
            SymairaFormRow("Scan Filter", description: "Optional name, service or device identifier.") {
                TextField("All nearby devices", text: $filter)
                    .textFieldStyle(.symaira)
                    .accessibilityLabel("Scan Filter")
                    .frame(idealWidth: 180)
            }
            SymairaFormRow("Scan Duration") {
                Picker("Scan Duration", selection: $duration) {
                    ForEach([3, 5, 10, 15], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .labelsHidden()
                Button("Scan Nearby Devices") {
                    Task { await model.startScan(seconds: duration, filter: filter) }
                }
                .symairaButtonStyle(.secondary)
            }
        }
        .disabled(!model.canScan)
    }

    @ViewBuilder
    private var scanResults: some View {
        switch model.scan {
        case .idle:
            EmptyView()
        case .scanning(let seconds):
            SymairaLoadingState("Scanning nearby devices for \(seconds) seconds…")
                .padding(.vertical, SymairaSpacing.small)
        case .failed(let message):
            SymairaNotice(message: message, tone: .critical)
        case .finished(let result):
            SymairaFormDivider()
            if result.devices.isEmpty {
                let message = result.totalSeen > 0
                    ? "Try a different filter or clear it and scan again."
                    : "Bring a device into range and make it discoverable, then scan again."
                SymairaFormRow("No Matching Devices", description: message)
            } else {
                SymairaFormRow("Scan Results", description: "\(result.shown) of \(result.totalSeen) devices shown")
                ForEach(result.devices) { device in
                    advertisementRow(device)
                }
            }
        }
    }

    private func advertisementRow(_ device: BleAdvertisement) -> some View {
        let connected = model.isConnected(device.id)
        let canDiscover = model.offers("ble.services") && (device.connectable != false || connected)
        let canDisconnect = model.offers("ble.disconnect") && connected
        let details = [device.id, device.rssi.map { "\($0) dBm" }, connected ? "Connected" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return SymairaFormRow(device.name ?? "Unnamed Device", description: details) {
            if canDiscover {
                Button("Discover Services") { discover(device) }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.radioIsBusy || model.access.blocksRadioActions)
            } else {
                SymairaStatusLabel("Discovery Unavailable", tone: .neutral)
            }
            if canDisconnect {
                Button("Disconnect") { disconnect(device.id) }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.radioIsBusy)
            }
        }
        .contextMenu {
            if canDiscover {
                Button("Discover Services") { discover(device) }
                    .disabled(model.radioIsBusy || model.access.blocksRadioActions)
            }
            if canDisconnect {
                Button("Disconnect") { disconnect(device.id) }.disabled(model.radioIsBusy)
            }
        }
    }

    private func discover(_ device: BleAdvertisement) {
        Task { await model.loadServices(device.id) }
    }

    private func disconnect(_ id: String) {
        Task { await model.disconnect(id) }
    }

    @ViewBuilder
    private var gattDetails: some View {
        switch model.gatt {
        case .idle:
            EmptyView()
        case .loading:
            SymairaLoadingState("Connecting and discovering services…")
        case .failed(let message):
            SymairaNotice(message: message, tone: .critical)
        case .loaded(let gatt):
            SymairaFormDivider()
            SymairaFormRow("Services", description: gatt.deviceId) {
                if model.isConnected(gatt.deviceId), model.offers("ble.disconnect") {
                    Button("Disconnect") { disconnect(gatt.deviceId) }
                        .symairaButtonStyle(.secondary)
                        .disabled(model.radioIsBusy)
                }
            }
            if gatt.services.isEmpty {
                SymairaFormRow("No Services", description: "The device did not report any services.")
            }
            ForEach(gatt.services) { service in
                SymairaFormRow(service.uuid, description: service.characteristics.isEmpty ? "No characteristics." : nil)
                ForEach(service.characteristics) { characteristic in
                    BLECharacteristicRow(
                        device: gatt.deviceId, service: service.uuid, characteristic: characteristic, model: model
                    )
                    .id(BleReading.key(device: gatt.deviceId, service: service.uuid, characteristic: characteristic.uuid))
                }
            }
        }
    }
}

@MainActor
private struct BLECharacteristicRow: View {
    let device: String
    let service: String
    let characteristic: BleCharacteristic
    let model: BluetoothModel
    @State private var isEditing = false
    @State private var hex = ""

    private var key: String { BleReading.key(device: device, service: service, characteristic: characteristic.uuid) }
    private var allowed: Bool { !model.radioIsBusy && !model.access.blocksRadioActions }
    private var canRead: Bool { characteristic.canRead && model.offers("ble.read") }
    private var canWrite: Bool { characteristic.canWrite && model.offers("ble.write") }

    var body: some View {
        SymairaFormRow(characteristic.uuid, description: description) {
            if canRead {
                Button("Read Value", action: read).symairaButtonStyle(.secondary).disabled(!allowed)
            }
            if canWrite {
                Button(isEditing ? "Close Write Field" : "Prepare Write") { isEditing.toggle() }
                    .symairaButtonStyle(.secondary)
                    .disabled(!allowed)
            }
        }
        .contextMenu {
            if canRead { Button("Read Value", action: read).disabled(!allowed) }
            if canWrite { Button("Prepare Write") { isEditing = true }.disabled(!allowed) }
        }
        if model.busy == key {
            SymairaLoadingState("Reading characteristic…")
        }
        if let value = model.readings[key] {
            Text(value.length == 0 ? "Empty Value" : value.valueHex)
                .symairaText(.monoSmall)
                .textSelection(.enabled)
        }
        if isEditing {
            let valid = BluetoothModel.normalizedHex(hex) != nil
            SymairaFormRow(
                "Hex Value",
                description: characteristic.writesWithResponse
                    ? "Enter 1 to 512 bytes."
                    : "Enter 1 to 512 bytes. This characteristic sends no acknowledgement."
            ) {
                TextField("01 ff 0a", text: $hex)
                    .textFieldStyle(.symaira)
                    .accessibilityLabel("Hex Value")
                Button("Review Write") {
                    Task {
                        await model.requestWrite(device: device, service: service, characteristic: characteristic, hex: hex)
                    }
                }
                .symairaButtonStyle(.secondary)
                .disabled(!valid)
            }
            .disabled(!allowed)
            if !valid && !hex.isEmpty { Text("Use complete hexadecimal byte pairs.").symairaText(.caption) }
        }
    }

    private var description: String {
        if !canRead && !canWrite { return "Read and write unavailable." }
        return characteristic.properties.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")
    }

    private func read() {
        Task { await model.read(device: device, service: service, characteristic: characteristic.uuid) }
    }
}

@MainActor
struct BLEActivityCard: View {
    let model: BluetoothModel
    @State private var exportedFile: BLELogDocument?
    @State private var exportName = ""
    @State private var showsExporter = false
    @State private var exportFailure: String?

    var body: some View {
        SymairaFormSection("BLE Activity") {
            if !model.offers("ble.log") && !model.offers("ble.export") {
                SymairaFormRow("Log Unavailable", description: "This agent does not offer BLE session logs.")
            } else {
                logControls
                if model.offers("ble.log") { entries }
                if model.isExporting { SymairaLoadingState("Preparing BLE export…") }
                if let exportFailure { SymairaNotice(message: exportFailure, tone: .critical) }
            }
        }
        .fileExporter(
            isPresented: $showsExporter, document: exportedFile,
            contentTypes: [exportedFile?.type ?? .json], defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                exportFailure = "The BLE log could not be saved. \(error.localizedDescription)"
            }
            exportedFile = nil
        } onCancellation: {
            exportedFile = nil
        }
    }

    private var logControls: some View {
        SymairaFormRow("Session Log", description: "Exports include raw bytes from the session.") {
            if model.offers("ble.log") {
                Button("Refresh Log") { Task { await model.loadLog() } }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.radioIsBusy || model.log == .loading)
            }
            if model.offers("ble.export") {
                Menu("Export Log") {
                    Button("Export CSV") { export(.csv) }
                    Button("Export JSON") { export(.json) }
                }
                .disabled(model.isExporting || model.radioIsBusy)
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        switch model.log {
        case .idle:
            EmptyView()
        case .loading:
            SymairaLoadingState("Loading BLE activity…")
        case .failed(let message):
            SymairaNotice(message: message, tone: .critical)
        case .loaded(let log):
            if log.entries.isEmpty {
                SymairaFormRow("No Activity Yet", description: "Start a scan or interact with a device to see its activity.")
            } else {
                let recent = log.entries.suffix(8).reversed()
                ForEach(recent) { entry in
                    SymairaFormDivider()
                    SymairaFormRow(
                        entry.kind.replacingOccurrences(of: "_", with: " ").capitalized, description: entryDetail(entry)
                    ) {
                        Text(entry.date, style: .time).symairaText(.caption).monospacedDigit()
                    }
                }
                if log.count > recent.count {
                    Text("Showing the latest \(recent.count) of \(log.count) entries. Export the full session log.")
                        .symairaText(.caption)
                }
            }
        }
    }

    private func entryDetail(_ entry: BleLogEntry) -> String {
        [entry.deviceId, entry.service, entry.characteristic, entry.valueHex, entry.detail]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func export(_ format: BleExportFormat) {
        exportFailure = nil
        Task {
            guard let export = await model.export(format) else { return }
            exportedFile = BLELogDocument(data: export.data, type: format == .csv ? .commaSeparatedText : .json)
            exportName = export.suggestedName
            showsExporter = true
        }
    }
}

private struct BLELogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }

    let data: Data
    let type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(data: data, type: configuration.contentType)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct CockpitInputCard: View {
    let model: InputModel

    var body: some View {
        SymairaPageState(state: model.status.devicePageState, loading: "Loading input settings…", retry: {
            Task { await model.refresh() }
        }) { status in
            SymairaFormSection("Input") {
                let finder = status.finderCut
                SymairaFormRow("Finder Cut", description: "Use ⌘X to cut selected files in Finder.") {
                    Toggle("Finder Cut", isOn: Binding(get: { finder.enabled }, set: { enabled in
                        Task { await model.setFinderCut(enabled) }
                    }))
                    .toggleStyle(.symairaSwitch)
                    .labelsHidden()
                    .disabled(model.isSwitching || (!finder.hasAccess && !finder.enabled))
                }
                SymairaFormDivider()
                accessibility(finder)
                SymairaFormDivider()
                SymairaFormRow("Haptic Feedback", description: status.haptics.state.explanation) {
                    Button("Test Feedback") { Task { await model.testHaptics() } }
                        .symairaButtonStyle(.secondary)
                        .disabled(model.isTesting)
                }
                if model.isTesting { SymairaLoadingState("Testing haptics and sound…") }
                if let result = model.testResult {
                    SymairaFormRow("Haptics", description: result.haptic.detail) { channelStatus(result.haptic) }
                    SymairaFormRow("Sound", description: result.sound.detail) { channelStatus(result.sound) }
                }
                if let failure = model.failure {
                    SymairaNotice(message: failure, tone: .critical)
                }
            }
        }
    }

    private func accessibility(_ finder: InputFinderCut) -> some View {
        SymairaFormRow("Accessibility", description: finder.hasAccess
            ? (finder.secureInputActive ? "Secure input is active. Finder Cut is temporarily paused." : nil)
            : "Allow Cockpit in Privacy & Security to enable Finder Cut."
        ) {
            SymairaStatusLabel(finder.hasAccess ? "Granted" : "Required", tone: finder.hasAccess ? .positive : .warning)
            if !finder.hasAccess {
                DeviceSettingsLink(
                    "Open Accessibility Privacy", pane: "com.apple.preference.security?Privacy_Accessibility"
                )
            }
        }
    }

    private func channelStatus(_ channel: InputChannel) -> some View {
        let title = switch channel.status {
        case "ok": "Test Completed"
        case "skipped_disabled": "Disabled"
        case "failed", "actuation_failed": "Test Failed"
        default: "Unavailable"
        }
        return SymairaStatusLabel(title, tone: channel.status == "ok" ? .positive : .warning)
    }
}

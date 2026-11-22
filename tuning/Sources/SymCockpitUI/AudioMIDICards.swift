import SwiftUI
import SymCockpitCore
import SymairaTheme

@MainActor
struct AudioDevicesCard: View {
    let direction: AudioDirection
    let list: AudioDeviceList
    let model: AudioMIDIModel
    @State private var selectedUID: String?

    private var devices: [AudioDevice] {
        list.devices.filter { $0.scope(direction).channels > 0 }
    }

    private var selection: Binding<String?> {
        Binding(get: {
            devices.first { $0.uid == selectedUID }?.uid
                ?? devices.first { $0.isDefault(direction) }?.uid
                ?? devices.first?.uid
        }, set: { selectedUID = $0 })
    }

    var body: some View {
        SymairaFormSection(direction.title) {
            if devices.isEmpty {
                SymairaFormRow("No \(direction.title) Devices", description: "Connect an audio device to see it here.")
            } else {
                SymairaFormRow("\(direction.title) Device") {
                    Picker("\(direction.title) Device", selection: selection) {
                        ForEach(devices) { device in
                            Text(device.isDefault(direction) ? "\(device.name) (Default)" : device.name)
                                .tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("\(direction.title) Device")
                    .disabled(model.controlsLocked)
                }
                if let device = devices.first(where: { $0.uid == selection.wrappedValue }) {
                    SymairaFormDivider()
                    AudioDeviceControls(direction: direction, device: device, model: model)
                        .id(device.uid)
                }
            }
        }
    }
}

@MainActor
private struct AudioDeviceControls: View {
    let direction: AudioDirection
    let device: AudioDevice
    let model: AudioMIDIModel
    @State private var showsFormat = false

    private var scope: AudioScopeState { device.scope(direction) }
    private var useDefaultTitle: String { "Set as Default \(direction.title)" }
    private var canSetDefault: Bool { device.online && !device.isDefault(direction) && !model.controlsLocked }

    var body: some View {
        SymairaFormRow(device.name, description: details) {
            if !device.online {
                SymairaStatusLabel("Offline", tone: .neutral)
            } else if device.isDefault(direction) {
                SymairaStatusLabel("Default", tone: .positive)
            } else {
                Button(useDefaultTitle, action: setDefault)
                    .symairaButtonStyle(.secondary)
                    .disabled(!canSetDefault)
            }
        }
        .contextMenu {
            Button(useDefaultTitle, action: setDefault).disabled(!canSetDefault)
        }

        if device.online {
            SymairaFormDivider()
            if let volume = scope.volume, scope.volumeSettable {
                AudioVolumeRow(title: "\(direction.title) Volume", reported: volume, disabled: model.controlsLocked) {
                    await model.setVolume($0, device: device, direction: direction)
                }
            } else {
                SymairaFormRow(
                    "\(direction.title) Volume",
                    description: scope.volume.map { "\(AudioVolumeRow.percent($0)) · Read only" }
                        ?? "Volume control is unavailable for this device."
                )
            }
            SymairaFormDivider()
            if let muted = scope.muted, scope.muteSettable {
                SymairaFormRow("Mute \(direction.title)") {
                    Toggle("Mute \(direction.title)", isOn: Binding(get: { muted }, set: { value in
                        Task { await model.setMuted(value, device: device, direction: direction) }
                    }))
                    .toggleStyle(.symairaSwitch)
                    .labelsHidden()
                    .disabled(model.controlsLocked)
                }
            } else {
                SymairaFormRow(
                    "Mute \(direction.title)",
                    description: scope.muted.map { $0 ? "Muted · Read only" : "Unmuted · Read only" }
                        ?? "Mute control is unavailable for this device."
                )
            }
            if direction == device.formatDirection {
                SymairaFormDivider()
                SymairaFormRow("Audio Format", description: formatDescription) {
                    Button(showsFormat ? "Close Format Options" : "Configure Format") {
                        showsFormat.toggle()
                    }
                    .symairaButtonStyle(.secondary)
                    .disabled(model.controlsLocked)
                }
                if showsFormat {
                    AudioFormatEditor(device: device, model: model)
                }
            }
        }
    }

    private var details: String {
        [device.manufacturer, "\(scope.channels) channels"].compactMap { $0 }.joined(separator: " · ")
    }

    private var formatDescription: String {
        let rate = device.sampleRate ?? scope.format?.rate
        let parts = [rate.map(AudioMIDIModel.hertz), scope.format.map { "\($0.bits)-bit" }].compactMap { $0 }
        return parts.isEmpty ? "Current format unavailable." : parts.joined(separator: " · ")
    }

    private func setDefault() {
        Task { await model.setDefault(direction, device: device) }
    }
}

@MainActor
private struct AudioFormatEditor: View {
    let device: AudioDevice
    let model: AudioMIDIModel
    @State private var options: LoadState<AudioFormatOptions> = .loading
    @State private var rate: Double?
    @State private var bits: Int?

    var body: some View {
        SymairaPageState(state: options.devicePageState, loading: "Loading audio formats…", retry: {
            Task { await load() }
        }) { loaded in
            let formats = loaded.formats(for: device.formatDirection)
            let reported = formats.map(\.rate) + [loaded.sampleRate].compactMap { $0 }
            let rates = AudioDevice.selectableRates(in: loaded.sampleRates, reported: reported)
            if rates.isEmpty {
                SymairaFormRow("Format Changes Unavailable", description: "The agent reports no selectable sample rates.")
            } else {
                let selectedRate = rate.flatMap { rates.contains($0) ? $0 : nil } ?? rates[0]
                let selectedBits = Set(formats.filter { abs($0.rate - selectedRate) < 0.5 }.map(\.bits)).sorted()
                SymairaFormRow("Sample Rate") {
                    Picker("Sample Rate", selection: Binding(get: { selectedRate }, set: { value in
                        rate = value
                        bits = nil
                    })) {
                        ForEach(rates, id: \.self) { value in
                            Text(AudioMIDIModel.hertz(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                }
                SymairaFormDivider()
                SymairaFormRow("Bit Depth", description: selectedBits.isEmpty ? "The device lists no bit depths for this rate." : nil) {
                    Picker("Bit Depth", selection: $bits) {
                        Text("Keep Current").tag(nil as Int?)
                        ForEach(selectedBits, id: \.self) { value in
                            Text("\(value)-bit").tag(Optional(value))
                        }
                    }
                    .labelsHidden()
                    .disabled(selectedBits.isEmpty)
                }
                SymairaFormRow("Review the format before applying it.") {
                    Button("Review Format Change") {
                        Task { await model.requestFormat(selectedRate, bits: bits, device: device) }
                    }
                    .symairaButtonStyle(.secondary)
                }
            }
        }
        .disabled(model.controlsLocked)
        .task { await load() }
    }

    private func load() async {
        options = .loading
        let result = await model.loadFormats(for: device)
        guard !Task.isCancelled else { return }
        rate = result.value?.sampleRate
        bits = nil
        options = result
    }
}

@MainActor
struct AudioAggregateCard: View {
    let list: AudioDeviceList
    let model: AudioMIDIModel
    @State private var isEditing = false
    @State private var name = ""
    @State private var memberUIDs: Set<String> = []
    @State private var main: String?
    @State private var multiOutput = false

    private var candidates: [AudioDevice] {
        list.aggregateCandidates.filter { !multiOutput || $0.offers(.output) }
    }

    var body: some View {
        SymairaFormSection("Aggregate & Multi-Output Devices") {
            let aggregates = list.devices.filter(\.isAggregate)
            if aggregates.isEmpty {
                SymairaFormRow("No Aggregate Devices", description: "Combine two or more audio devices into one.")
            }
            ForEach(aggregates) { device in
                SymairaFormRow(device.name, description: device.members.map { "\($0.count) members" }) {
                    SymairaStatusLabel(device.online ? "Online" : "Offline", tone: device.online ? .positive : .neutral)
                }
            }
            if candidates.count < 2 && !isEditing {
                SymairaFormRow(
                    "Creation Unavailable", description: "Connect at least two compatible audio devices."
                )
            } else if isEditing {
                editor.disabled(model.controlsLocked)
            } else {
                SymairaFormRow("Combine Audio Devices") {
                    Button("Configure New Device") { isEditing = true }
                        .symairaButtonStyle(.secondary)
                        .disabled(model.controlsLocked)
                }
            }
        }
    }

    private var editor: some View {
        let selected = candidates.filter { memberUIDs.contains($0.uid) }
        let problem = AudioMIDIModel.aggregateProblem(name: name, memberCount: selected.count)
        return VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            SymairaFormDivider()
            SymairaFormRow("Device Name") {
                TextField("New audio device", text: $name)
                    .textFieldStyle(.symaira)
                    .accessibilityLabel("Device Name")
            }
            SymairaFormDivider()
            SymairaFormRow("Multi-Output", description: "Play the same audio on every member.") {
                Toggle("Multi-Output", isOn: $multiOutput).toggleStyle(.symairaSwitch).labelsHidden()
            }
            ForEach(candidates) { device in
                SymairaFormRow(device.name) {
                    Toggle(device.name, isOn: Binding(get: { memberUIDs.contains(device.uid) }, set: { enabled in
                        if enabled { memberUIDs.insert(device.uid) } else { memberUIDs.remove(device.uid) }
                        if !enabled, main == device.uid { main = nil }
                    }))
                    .toggleStyle(.symairaSwitch)
                    .labelsHidden()
                }
            }
            if !selected.isEmpty {
                SymairaFormRow("Clock Source") {
                    Picker("Clock Source", selection: Binding(get: {
                        selected.contains { $0.uid == main } ? main : nil
                    }, set: { main = $0 })) {
                        Text("First Member").tag(nil as String?)
                        ForEach(selected) { device in Text(device.name).tag(Optional(device.uid)) }
                    }
                    .labelsHidden()
                }
            }
            if let problem { Text(problem).symairaText(.caption) }
            HStack(spacing: SymairaSpacing.small) {
                Button("Cancel", role: .cancel) { isEditing = false }.symairaButtonStyle(.secondary)
                Button("Review New Device") {
                    let source = selected.first { $0.uid == main }?.uid
                    Task {
                        await model.requestAggregate(
                            name: name, members: selected.map(\.uid), main: source, multiOutput: multiOutput
                        )
                    }
                }
                .symairaButtonStyle(.secondary)
                .disabled(problem != nil)
            }
            .padding(.vertical, SymairaSpacing.small)
        }
    }
}

@MainActor
struct AudioMixerCard: View {
    let model: AudioMIDIModel
    let retry: () -> Void

    var body: some View {
        SymairaPageState(state: model.mixer.devicePageState, loading: "Loading app mixer…", retry: retry) { status in
            SymairaFormSection("App Mixer") {
                if !status.supported {
                    SymairaFormRow("Mixer Unavailable", description: "This Mac does not offer per-app volume to the agent.")
                } else {
                    mixerControls(status)
                }
            }
        }
    }

    @ViewBuilder
    private func mixerControls(_ status: MixerStatus) -> some View {
        let apps = model.mixerApps
        let controlling = status.managed?.contains { $0.state == "active" } == true
        let waiting = status.managed?.contains { $0.state == "pending" } == true
        if status.mixerRunning {
            let label = controlling ? "Active" : waiting ? "Waiting for Audio" : "Ready"
            SymairaFormRow("Mixer", description: "Changing an app’s volume or mute starts mixing for that app.") {
                SymairaStatusLabel(label, tone: controlling ? .positive : .neutral)
            }
        } else {
            SymairaFormRow("Mixer Session Unavailable", description: "This agent offers no independent mixer start.")
        }
        SymairaFormDivider()
        captureAccess
        if apps.isEmpty {
            SymairaFormDivider()
            SymairaFormRow("No Audio Apps", description: "Play audio in an app to see it here.")
        }
        ForEach(apps) { app in
            SymairaFormDivider()
            mixerApp(app, enabled: status.mixerRunning)
        }
    }

    @ViewBuilder
    private var captureAccess: some View {
        switch model.captureAccess {
        case .unsupported:
            SymairaFormRow("System Audio Recording", description: "Unavailable on this Mac.")
        case .unknown:
            SymairaFormRow(
                "System Audio Recording",
                description: "The agent cannot check this permission in advance. macOS may ask when you change an app’s volume or mute."
            )
        case .activeCapture:
            SymairaFormRow("System Audio Recording") { SymairaStatusLabel("Capture Active", tone: .positive) }
        case .denied(let message):
            SymairaFormRow("System Audio Recording", description: message)
        }
    }

    private func mixerApp(_ app: MixerApp, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SymairaFormRow(app.name, description: app.detail) {
                SymairaStatusLabel(appStatus(app), tone: app.state == "failed" ? .critical : .neutral)
            }
            AudioVolumeRow(
                title: "App Volume", accessibilityName: "Volume for \(app.name)",
                reported: app.volume, disabled: !enabled || model.controlsLocked
            ) {
                await model.setAppVolume($0, muted: app.muted, app: app)
            }
            SymairaFormRow("Mute App") {
                Toggle("Mute \(app.name)", isOn: Binding(get: { app.muted }, set: { muted in
                    Task { await model.setAppVolume(app.volume, muted: muted, app: app) }
                }))
                .toggleStyle(.symairaSwitch)
                .labelsHidden()
                .disabled(!enabled || model.controlsLocked)
            }
        }
    }

    private func appStatus(_ app: MixerApp) -> String {
        switch app.state {
        case "active": "Mixing"
        case "pending": "Waiting for Audio"
        case "failed": "Mixer Error"
        default: app.isPlaying ? "Playing" : "Idle"
        }
    }
}

@MainActor
private struct AudioVolumeRow: View {
    let title: String
    var accessibilityName: String? = nil
    let reported: Double
    let disabled: Bool
    let apply: (Double) async -> Void
    @State private var draft: Double?

    var body: some View {
        let value = draft ?? reported
        SymairaFormRow(title, description: "Current level: \(Self.percent(reported))") {
            HStack(spacing: SymairaSpacing.small) {
                Slider(value: Binding(get: { value }, set: { draft = $0 }), in: 0...1) {
                    Text(accessibilityName ?? title)
                }
                .labelsHidden()
                .accessibilityValue(Self.percent(value))
                .frame(idealWidth: 120)
                Text(Self.percent(value)).symairaText(.caption).monospacedDigit()
                Button("Set Volume") {
                    Task {
                        await apply(value)
                        draft = nil
                    }
                }
                .symairaButtonStyle(.secondary)
                .disabled(draft == nil)
            }
            .disabled(disabled)
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
